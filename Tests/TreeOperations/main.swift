import Foundation

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

// Unique so the trash cleanup at the end can only ever touch our own files.
let stamp = "sahifa-treetest-\(getpid())"
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(stamp)
let fm = FileManager.default
try! fm.createDirectory(at: root.appendingPathComponent("projects/alpha"),
                        withIntermediateDirectories: true)
func write(_ relative: String, _ text: String = "# x\n") {
    try! text.write(to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
}
write("root.md")
write("spare.md")
write("projects/plan.md")
write("projects/alpha/deep.md")

// MARK: ID algebra — the part a folder rename depends on

let sourceID = UUID()
func id(_ path: String) -> DocumentID { DocumentID(sourceID: sourceID, path: path) }

check("a path is within itself", id("projects").isWithin(id("projects")))
check("a child is within its folder", id("projects/plan.md").isWithin(id("projects")))
check("a grandchild is within its folder", id("projects/alpha/deep.md").isWithin(id("projects")))
check("everything is within the root", id("projects/alpha/deep.md").isWithin(id("")))
check("a sibling is NOT within", !id("root.md").isWithin(id("projects")))
check("a name prefix is NOT within",
      !id("projects-archive/x.md").isWithin(id("projects")))
check("another source is NOT within",
      !DocumentID(sourceID: UUID(), path: "projects/plan.md").isWithin(id("projects")))

check("renaming a folder moves its grandchild",
      id("projects/alpha/deep.md").remapping(from: id("projects"), to: id("work"))
        == id("work/alpha/deep.md"))
check("renaming a folder moves the folder itself",
      id("projects").remapping(from: id("projects"), to: id("work")) == id("work"))
check("an unaffected path remaps to nil",
      id("root.md").remapping(from: id("projects"), to: id("work")) == nil)

// MARK: Opened files on a drive that isn't plugged in

@MainActor
func unpluggedDrive() async {
    let volumes = root.appendingPathComponent("Volumes")
    let drive = volumes.appendingPathComponent("Drive")
    let file = drive.appendingPathComponent("away.md")
    func plugIn() {
        try? fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try? "# away\n".write(to: file, atomically: true, encoding: .utf8)
    }
    func listed(_ model: AppModel) -> Bool {
        model.looseFiles.contains { $0.standardizedFileURL.path == file.standardizedFileURL.path }
    }
    func remembered() -> Int { (UserDefaults.standard.array(forKey: "looseFiles") as? [Data])?.count ?? 0 }
    AppModel.volumesDirectory = volumes.path
    defer { AppModel.volumesDirectory = "/Volumes" }
    // This binary's own defaults: a run that crashed can't leave files behind.
    UserDefaults.standard.removeObject(forKey: "looseFiles")

    plugIn()
    let model = AppModel()
    let window = WindowState()
    window.attach(model)
    model.openExternal([file], preferring: window)
    check("a file opened from a drive is listed", listed(model))

    try? fm.removeItem(at: drive)
    model.refreshLoadedDirectories()
    check("once the drive is unplugged it drops out of the list", !listed(model))
    check("…but is still remembered", remembered() == 1, "\(remembered()) saved")

    let relaunched = AppModel()
    check("a relaunch without the drive keeps it too", remembered() == 1 && !listed(relaunched))
    plugIn()
    relaunched.refreshLoadedDirectories()
    check("plugging the drive back in lists it again", listed(relaunched))

    try? fm.removeItem(at: file)
    relaunched.refreshLoadedDirectories()
    check("a file deleted from a drive that is plugged in is forgotten",
          !listed(relaunched) && remembered() == 0, "\(remembered()) saved")
    relaunched.removeSource(Source.looseFilesID)
}

// MARK: A source folder renamed or moved while the app runs

@MainActor
func renamedRoot() async {
    let folder = root.appendingPathComponent("watched")
    try? fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try? "# one\n".write(to: folder.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
    let model = AppModel()
    model.openExternal([folder])
    guard let source = model.sources.first(where: {
        $0.rootURL?.standardizedFileURL == folder.standardizedFileURL
    }) else { check("the folder is added as a source", false); return }
    let rootID = DocumentID(sourceID: source.id, path: "")
    func current() -> Source? { model.source(source.id) }
    // /var is /private/var, which a path that no longer exists won't resolve.
    func path(_ url: URL?) -> String? {
        url.map {
            var parts = $0.resolvingSymlinksInPath().pathComponents
            if parts.count > 1, parts[1] == "private" { parts.remove(at: 1) }
            return NSString.path(withComponents: parts)
        }
    }
    func waitUntil(_ condition: () -> Bool) async -> Int {
        var waited = 0
        while !condition(), waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        return waited * 100
    }

    let document = model.document(for: DocumentID(sourceID: source.id, path: "one.md"))
    document?.text = "# one\n\ntyped before the rename\n"
    // The app finishes setting the source up on the next turn of the main
    // loop; a user can't rename the folder before that.
    try? await Task.sleep(nanoseconds: 100_000_000)
    let renamed = root.appendingPathComponent("watched-renamed")
    try? fm.moveItem(at: folder, to: renamed)
    var ms = await waitUntil { path(current()?.rootURL) == path(renamed) }
    check("a source folder renamed in Finder is followed to its new path",
          path(current()?.rootURL) == path(renamed), "after \(ms) ms")
    check("…and takes the new name", current()?.name == "watched-renamed", current()?.name ?? "nil")
    check("…and stays ready", current()?.status == .ready)
    check("…still listing its files", model.children(of: rootID)?.contains { $0.name == "one.md" } == true)
    await document?.flush()
    let onDisk = try? String(contentsOf: renamed.appendingPathComponent("one.md"), encoding: .utf8)
    check("…and edits made before the rename save into the renamed folder",
          onDisk == "# one\n\ntyped before the rename\n", onDisk ?? "nil")

    try? "# two\n".write(to: renamed.appendingPathComponent("two.md"), atomically: true, encoding: .utf8)
    ms = await waitUntil { model.children(of: rootID)?.contains { $0.name == "two.md" } == true }
    check("…and the watcher follows it: a file added there shows up",
          model.children(of: rootID)?.contains { $0.name == "two.md" } == true, "after \(ms) ms")

    // Moved to the Trash, the bookmark still finds it; the sidebar must not.
    let trash = root.appendingPathComponent(".Trash")
    try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
    try? fm.moveItem(at: renamed, to: trash.appendingPathComponent("watched-renamed"))
    ms = await waitUntil { current()?.status == .missing }
    check("a source folder moved to the Trash is missing, not followed",
          current()?.status == .missing && path(current()?.rootURL) == path(renamed),
          "after \(ms) ms")
    model.removeSource(source.id)
}

// MARK: Real file operations

@MainActor
func fileOperations() async {
    let model = AppModel()
    model.openExternal([root])
    guard let source = model.sources.first(where: { $0.kind == .localFolder }) else {
        check("source added", false, "no local source")
        return
    }
    func docID(_ path: String) -> DocumentID { DocumentID(sourceID: source.id, path: path) }
    func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    check("source lists the tree root", model.children(of: docID(""))?.isEmpty == false)

    // Rename a file, keeping the extension the user didn't type.
    let renamed = try? await model.rename(docID("root.md"), to: "renamed")
    check("rename returns the new id", renamed == docID("renamed.md"), String(describing: renamed))
    check("…the file moved on disk", exists("renamed.md") && !exists("root.md"))

    // Rename with an explicit extension is taken as given.
    let explicit = try? await model.rename(docID("spare.md"), to: "kept.markdown")
    check("an explicit extension is honoured", explicit == docID("kept.markdown"))
    check("…and moved on disk", exists("kept.markdown") && !exists("spare.md"))

    // Rejections.
    check("empty name refused", (try? await model.rename(docID("renamed.md"), to: "   ")) == nil)
    check("slash refused", (try? await model.rename(docID("renamed.md"), to: "a/b.md")) == nil)
    check("dotfile refused", (try? await model.rename(docID("renamed.md"), to: ".hidden")) == nil)
    check("collision refused",
          (try? await model.rename(docID("renamed.md"), to: "kept.markdown")) == nil)
    check("…and nothing moved", exists("renamed.md") && exists("kept.markdown"))

    // Rename a folder: every descendant id has to move with it.
    var moves: [(from: DocumentID, to: DocumentID?)] = []
    let token = model.documentMoved.sink { moves.append($0) }
    model.loadChildren(of: docID("projects"))
    model.loadChildren(of: docID("projects/alpha"))
    let folder = try? await model.rename(docID("projects"), to: "work")
    check("folder rename returns the new id", folder == docID("work"))
    check("…the folder moved on disk",
          exists("work/alpha/deep.md") && !exists("projects/plan.md"))
    check("…and it announced the move",
          moves.last?.from == docID("projects") && moves.last?.to == docID("work"))
    check("…stale children were dropped from the cache",
          model.children(of: docID("projects")) == nil
            && model.children(of: docID("projects/alpha")) == nil)
    model.loadChildren(of: docID("work"))
    check("…the new path lists correctly",
          model.children(of: docID("work"))?.contains { $0.name == "plan.md" } == true)

    // A newly added source must open in a window that already has a document.
    // Left collapsed it appears as a bare name at the bottom of the list while
    // its contents load invisibly, which reads as the Add button doing nothing.
    do {
        let window = WindowState()
        window.attach(model)
        window.selection = docID("renamed.md")
        let already = window.selection
        try? fm.createDirectory(at: root.appendingPathComponent("second"),
                                withIntermediateDirectories: true)
        write("second/note.md")
        model.openExternal([root.appendingPathComponent("second")])
        guard let added = model.sources.first(where: { $0.name == "second" }) else {
            check("second source added", false); return
        }
        let addedRoot = DocumentID(sourceID: added.id, path: "")
        check("a source added while a document is open still expands",
              window.expanded.contains(addedRoot))
        check("…and the open document is left alone",
              window.selection == already, String(describing: window.selection))
    }

    // A dot in the new name isn't an extension unless Sahifa opens it: the
    // file keeps .md rather than becoming a ".0" file the tree won't list.
    let dotted = try? await model.rename(docID("renamed.md"), to: "Release 1.0")
    check("a dotted name keeps the extension", dotted == docID("Release 1.0.md"),
          String(describing: dotted))
    _ = try? await model.rename(docID("Release 1.0.md"), to: "renamed")
    check("…and renames back", exists("renamed.md"))
    check("a folder takes its new name exactly",
          (try? AppModel.renamedName("archive", from: "v1.2", isDirectory: true)) == "archive")
    check("a file renamed to another openable type takes it",
          (try? AppModel.renamedName("data.csv", from: "notes.md", isDirectory: false)) == "data.csv")
    check("a colon is refused",
          (try? AppModel.renamedName("a:b", from: "notes.md", isDirectory: false)) == nil)

    // Refusals say why, so the sidebar can show it.
    do {
        _ = try await model.rename(docID("renamed.md"), to: "KEPT.markdown")
        check("a name differing only in case is refused", false)
    } catch {
        check("a name differing only in case is refused",
              error as? OrganiseError == .nameTaken("KEPT.markdown"), "\(error)")
    }
    do {
        _ = try await model.rename(docID("renamed.md"), to: "  ")
        check("an empty name throws invalidName", false)
    } catch {
        check("an empty name throws invalidName", error as? OrganiseError == .invalidName)
    }

    // Edits typed just before a rename land in the renamed file, and the old
    // model never writes the old name back.
    do {
        guard let doc = model.document(for: docID("renamed.md")) else {
            check("open renamed.md", false); return
        }
        doc.text = "# typed before the rename\n"
        let moved = try? await model.rename(docID("renamed.md"), to: "moved")
        check("rename with unsaved edits succeeds", moved == docID("moved.md"))
        let onDisk = try? String(contentsOf: root.appendingPathComponent("moved.md"), encoding: .utf8)
        check("…the edits reached the renamed file", onDisk == "# typed before the rename\n",
              String(describing: onDisk))
        // What a window does with its outgoing document when it switches.
        doc.text += "late\n"
        doc.saveNow()
        await doc.waitForSave()
        check("…the old model can't recreate the old name", !exists("renamed.md"))
        _ = try? await model.rename(docID("moved.md"), to: "renamed")
    }

    // Trashing a document with unsaved edits must not bring it back. The old
    // model used to save on the way out and recreate the file in place.
    do {
        let doomedName = "\(stamp)-doomed.md"
        write(doomedName)
        model.loadChildren(of: docID(""), force: true)
        guard let doc = model.document(for: docID(doomedName)) else {
            check("open the doomed file", false); return
        }
        doc.text = "# unsaved\n"
        try? await model.delete(docID(doomedName))
        check("a dirty document is trashed", !exists(doomedName))
        doc.saveNow()
        await doc.waitForSave()
        await doc.flush()
        check("…and stays trashed when the old model saves", !exists(doomedName))
    }

    // Delete (local → Trash).
    try? await model.delete(docID("kept.markdown"))
    check("delete removes the file", !exists("kept.markdown"))
    check("…and announced a deletion",
          moves.last?.from == docID("kept.markdown") && moves.last?.to == nil)
    check("a local delete does not need confirming",
          !model.deletionNeedsConfirmation(docID("renamed.md")))

    // New file, through the store now.
    let created = try? await model.newFile(in: docID(""))
    check("a new file is created", created != nil, String(describing: created))
    check("…and exists on disk",
          created.map { exists(($0.path as NSString).lastPathComponent) } == true)

    // Drag-to-reorder the source roots.
    let orderBefore = model.sources.map(\.id)
    check("two source roots to reorder", orderBefore.count >= 2, "count \(orderBefore.count)")
    if orderBefore.count >= 2 {
        model.moveSources(fromOffsets: IndexSet(integer: 0), toOffset: orderBefore.count)
        let orderAfter = model.sources.map(\.id)
        check("moving the first root to the end reorders the list",
              orderAfter.first == orderBefore[1] && orderAfter.last == orderBefore[0])

        // Move Up / Move Down — the collapse-proof reorder.
        let a = model.sources.map(\.id)
        model.moveSourceDown(a[0])
        check("move down swaps a root with the next", model.sources.map(\.id) == [a[1], a[0]])
        model.moveSourceUp(a[0])
        check("move up puts it back", model.sources.map(\.id) == a)
    }
    _ = token
}

await unpluggedDrive()
await renamedRoot()
await fileOperations()

// Clean up our own trashed test files rather than leaving litter behind.
let trash = fm.urls(for: .trashDirectory, in: .userDomainMask).first
if let trash, let entries = try? fm.contentsOfDirectory(atPath: trash.path) {
    for entry in entries where entry.hasPrefix("kept") || entry.hasPrefix(stamp) {
        // Only files this run created, matched by our unique name.
        try? fm.removeItem(at: trash.appendingPathComponent(entry))
    }
}
try? fm.removeItem(at: root)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
