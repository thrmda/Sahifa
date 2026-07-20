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
    let renamed = await model.rename(docID("root.md"), to: "renamed")
    check("rename returns the new id", renamed == docID("renamed.md"), String(describing: renamed))
    check("…the file moved on disk", exists("renamed.md") && !exists("root.md"))

    // Rename with an explicit extension is taken as given.
    let explicit = await model.rename(docID("spare.md"), to: "kept.markdown")
    check("an explicit extension is honoured", explicit == docID("kept.markdown"))
    check("…and moved on disk", exists("kept.markdown") && !exists("spare.md"))

    // Rejections.
    check("empty name refused", await model.rename(docID("renamed.md"), to: "   ") == nil)
    check("slash refused", await model.rename(docID("renamed.md"), to: "a/b.md") == nil)
    check("dotfile refused", await model.rename(docID("renamed.md"), to: ".hidden") == nil)
    check("collision refused",
          await model.rename(docID("renamed.md"), to: "kept.markdown") == nil)
    check("…and nothing moved", exists("renamed.md") && exists("kept.markdown"))

    // Rename a folder: every descendant id has to move with it.
    var moves: [(from: DocumentID, to: DocumentID?)] = []
    let token = model.documentMoved.sink { moves.append($0) }
    model.loadChildren(of: docID("projects"))
    model.loadChildren(of: docID("projects/alpha"))
    let folder = await model.rename(docID("projects"), to: "work")
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

    // Delete (local → Trash).
    await model.delete(docID("kept.markdown"))
    check("delete removes the file", !exists("kept.markdown"))
    check("…and announced a deletion",
          moves.last?.from == docID("kept.markdown") && moves.last?.to == nil)
    check("a local delete does not need confirming",
          !model.deletionNeedsConfirmation(docID("renamed.md")))

    // New file, through the store now.
    let created = await model.newFile(in: docID(""))
    check("a new file is created", created != nil, String(describing: created))
    check("…and exists on disk",
          created.map { exists(($0.path as NSString).lastPathComponent) } == true)
    _ = token
}

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
