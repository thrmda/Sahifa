import Foundation

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sahifa-conflict-\(getpid())", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

/// Every source is local here, so one stand-in source resolves the IDs.
let testSource = Source(id: UUID(), kind: .localFolder, name: "test", rootURL: dir)
let testStore = LocalFileStore(sourceID: testSource.id, root: dir)

func makeFile(_ name: String, _ contents: String) -> URL {
    let url = dir.appendingPathComponent(name)
    try! contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
func makeDocument(_ url: URL) -> DocumentModel {
    DocumentModel(id: testSource.documentID(for: url)!, store: testStore)
}
func onDisk(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
}
/// Conflict resolution kicks off a task; give it a moment to finish.
@MainActor
func settle() async {
    try? await Task.sleep(nanoseconds: 300_000_000)
}

/// Another program writing the file.
func externalWrite(_ url: URL, _ contents: String) {
    try! contents.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: The store's own contract

@MainActor
func storeContract() async {
    let url = makeFile("store.md", "one")
    let id = testSource.documentID(for: url)!
    let first = testStore.version(of: id)
    check("a stored document has a version", first != nil)
    let readBack = testStore.readImmediately(id)
    check("reading returns text and that version",
          readBack?.text == "one" && readBack?.version == first)

    let next = try! await testStore.write("two", to: id, expecting: first)
    check("writing at the expected version moves it on", next != nil && next != first)
    check("…and the text landed", onDisk(url) == "two", onDisk(url))

    // Writing against a version someone else has moved past must be refused.
    externalWrite(url, "theirs")
    var refused = false
    do { _ = try await testStore.write("mine", to: id, expecting: next) }
    catch DocumentStoreError.versionConflict { refused = true }
    catch {}
    check("writing at a stale version is refused", refused)
    check("…leaving their text alone", onDisk(url) == "theirs", onDisk(url))

    let missing = testSource.documentID(for: dir.appendingPathComponent("nope.md"))!
    check("an absent document has no version", testStore.version(of: missing) == nil)
    let wrote = try? await testStore.write("new", to: missing, expecting: nil)
    check("…and is writable, so nothing is lost", wrote != nil)
}

@MainActor
func documentBehaviour() async {
    // 1. No local edits + external change → follow the file silently.
    do {
        let url = makeFile("clean.md", "original")
        let doc = makeDocument(url)
        externalWrite(url, "from another app")
        doc.reconcileWithDisk()
        check("clean document follows the file", doc.text == "from another app", doc.text)
        check("…without raising a conflict", !doc.hasConflict)
    }

    // 2. Local edits + external change → conflict, and the file is untouched.
    do {
        let url = makeFile("conflict.md", "original")
        let doc = makeDocument(url)
        doc.text = "my unsaved edit"
        externalWrite(url, "their edit")
        await doc.flush()
        check("autosave refuses to overwrite", doc.hasConflict)
        check("…leaving their version on disk", onDisk(url) == "their edit", onDisk(url))
        check("…and keeping mine in the editor", doc.text == "my unsaved edit")

        // Autosave must stay paused while unresolved.
        doc.text = "my unsaved edit, extended"
        await doc.flush()
        check("further autosaves stay paused", onDisk(url) == "their edit", onDisk(url))
    }

    // 3. Resolve by keeping mine → my text wins, conflict clears.
    do {
        let url = makeFile("keep.md", "original")
        let doc = makeDocument(url)
        doc.text = "mine"
        externalWrite(url, "theirs")
        await doc.flush()
        check("conflict raised", doc.hasConflict)
        doc.resolveKeepingMine()
        await settle()
        check("keep-mine writes my version", onDisk(url) == "mine", onDisk(url))
        check("…and clears the conflict", !doc.hasConflict)

        // Autosave works again afterwards.
        doc.text = "mine, later"
        await doc.flush()
        check("autosave resumes after resolving", onDisk(url) == "mine, later", onDisk(url))
    }

    // 4. Resolve by using disk → their text wins.
    do {
        let url = makeFile("reload.md", "original")
        let doc = makeDocument(url)
        doc.text = "mine"
        externalWrite(url, "theirs")
        await doc.flush()
        check("conflict raised", doc.hasConflict)
        doc.resolveUsingDisk()
        check("reload takes their version", doc.text == "theirs", doc.text)
        check("…and clears the conflict", !doc.hasConflict)
    }

    // 5. Untouched file: normal autosave still writes.
    do {
        let url = makeFile("normal.md", "original")
        let doc = makeDocument(url)
        doc.text = "edited normally"
        await doc.flush()
        check("ordinary autosave still writes", onDisk(url) == "edited normally", onDisk(url))
        check("…with no conflict", !doc.hasConflict)
    }

    // 6. Deleted file: writing recreates it rather than dropping the text.
    do {
        let url = makeFile("deleted.md", "original")
        let doc = makeDocument(url)
        doc.text = "still wanted"
        try? FileManager.default.removeItem(at: url)
        await doc.flush()
        check("a deleted file is recreated, not lost", onDisk(url) == "still wanted", onDisk(url))
    }

    // 7. Same-length external edit — the case a size-only check would miss.
    do {
        let url = makeFile("samesize.md", "aaaa")
        let doc = makeDocument(url)
        doc.text = "bbbb"
        externalWrite(url, "cccc")
        await doc.flush()
        check("same-length external edit is still detected", doc.hasConflict)
        check("…leaving their version on disk", onDisk(url) == "cccc", onDisk(url))
    }

    // 8. A symlinked document: the save reaches the real file, the link stays
    //    a link, and an edit to the target is seen as a conflict.
    do {
        let target = makeFile("target.md", "original")
        let link = dir.appendingPathComponent("link.md")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let doc = makeDocument(link)
        doc.text = "saved through the link"
        await doc.flush()
        let attributes = try? FileManager.default.attributesOfItem(atPath: link.path)
        check("saving through a symlink keeps the link",
              attributes?[.type] as? FileAttributeType == .typeSymbolicLink)
        check("…and writes the real file", onDisk(target) == "saved through the link", onDisk(target))
        doc.text = "mine"
        externalWrite(target, "changed at the target, longer")
        await doc.flush()
        check("…an edit to the target is a conflict", doc.hasConflict)
    }

    // 9. A file locked against writing is not replaced by an atomic save.
    do {
        let url = makeFile("locked.md", "locked")
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let doc = makeDocument(url)
        doc.text = "should not land"
        await doc.flush()
        check("a read-only file is left alone", onDisk(url) == "locked", onDisk(url))
        check("…and the save says it failed", doc.saveStatus == .failed && doc.hasUnsavedChanges,
              String(describing: doc.saveStatus))
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    // 10. Paths reported through a symlinked root (FSEvents gives real paths)
    //     still map into the source.
    do {
        let real = dir.appendingPathComponent("realroot", isDirectory: true)
        try? FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("aliasroot")
        try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let source = Source(id: UUID(), kind: .localFolder, name: "alias", rootURL: alias)
        let reported = real.resolvingSymlinksInPath().appendingPathComponent("sub")
        check("a real path under a symlinked root maps into the source",
              source.documentID(for: reported)?.path == "sub",
              String(describing: source.documentID(for: reported)))
    }
}

await storeContract()
await documentBehaviour()
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
