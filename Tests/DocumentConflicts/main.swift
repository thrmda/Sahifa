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

func makeFile(_ name: String, _ contents: String) -> URL {
    let url = dir.appendingPathComponent(name)
    try! contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}
func onDisk(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
}
/// Another program writing the file.
func externalWrite(_ url: URL, _ contents: String) {
    try! contents.write(to: url, atomically: true, encoding: .utf8)
}

MainActor.assumeIsolated {
    // 1. No local edits + external change → follow the file silently.
    do {
        let url = makeFile("clean.md", "original")
        let doc = DocumentModel(url: url)
        externalWrite(url, "from another app")
        doc.reconcileWithDisk()
        check("clean document follows the file", doc.text == "from another app", doc.text)
        check("…without raising a conflict", !doc.hasConflict)
    }

    // 2. Local edits + external change → conflict, and the file is untouched.
    do {
        let url = makeFile("conflict.md", "original")
        let doc = DocumentModel(url: url)
        doc.text = "my unsaved edit"
        externalWrite(url, "their edit")
        doc.saveNow()
        check("autosave refuses to overwrite", doc.hasConflict)
        check("…leaving their version on disk", onDisk(url) == "their edit", onDisk(url))
        check("…and keeping mine in the editor", doc.text == "my unsaved edit")

        // Autosave must stay paused while unresolved.
        doc.text = "my unsaved edit, extended"
        doc.saveNow()
        check("further autosaves stay paused", onDisk(url) == "their edit", onDisk(url))
    }

    // 3. Resolve by keeping mine → my text wins, conflict clears.
    do {
        let url = makeFile("keep.md", "original")
        let doc = DocumentModel(url: url)
        doc.text = "mine"
        externalWrite(url, "theirs")
        doc.saveNow()
        check("conflict raised", doc.hasConflict)
        doc.resolveKeepingMine()
        check("keep-mine writes my version", onDisk(url) == "mine", onDisk(url))
        check("…and clears the conflict", !doc.hasConflict)

        // Autosave works again afterwards.
        doc.text = "mine, later"
        doc.saveNow()
        check("autosave resumes after resolving", onDisk(url) == "mine, later", onDisk(url))
    }

    // 4. Resolve by using disk → their text wins.
    do {
        let url = makeFile("reload.md", "original")
        let doc = DocumentModel(url: url)
        doc.text = "mine"
        externalWrite(url, "theirs")
        doc.saveNow()
        check("conflict raised", doc.hasConflict)
        doc.resolveUsingDisk()
        check("reload takes their version", doc.text == "theirs", doc.text)
        check("…and clears the conflict", !doc.hasConflict)
    }

    // 5. Untouched file: normal autosave still writes.
    do {
        let url = makeFile("normal.md", "original")
        let doc = DocumentModel(url: url)
        doc.text = "edited normally"
        doc.saveNow()
        check("ordinary autosave still writes", onDisk(url) == "edited normally", onDisk(url))
        check("…with no conflict", !doc.hasConflict)
    }

    // 6. Deleted file: writing recreates it rather than dropping the text.
    do {
        let url = makeFile("deleted.md", "original")
        let doc = DocumentModel(url: url)
        doc.text = "still wanted"
        try? FileManager.default.removeItem(at: url)
        doc.saveNow()
        check("a deleted file is recreated, not lost", onDisk(url) == "still wanted", onDisk(url))
    }

    // 7. Same-length external edit — the case a size-only check would miss.
    do {
        let url = makeFile("samesize.md", "aaaa")
        let doc = DocumentModel(url: url)
        doc.text = "bbbb"
        externalWrite(url, "cccc")
        doc.saveNow()
        check("same-length external edit is still detected", doc.hasConflict)
        check("…leaving their version on disk", onDisk(url) == "cccc", onDisk(url))
    }
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
