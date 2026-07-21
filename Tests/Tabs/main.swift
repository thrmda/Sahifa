// Regression tests for the in-window document tabs (WindowState.openTabs):
// opening adds a tab, switching re-activates rather than duplicating, closing
// falls back to a neighbour, and a rename/delete remaps or drops the tab.
//
// Drives a real AppModel + WindowState against a temp folder — no UI. The tab
// bookkeeping is synchronous (selection didSet → openSelected), and rename/
// delete emit `documentMoved`, whose sink runs before the async call returns.

import Foundation

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

let stamp = "sahifa-tabtest-\(getpid())"
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(stamp)
let fm = FileManager.default
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
func write(_ relative: String, _ text: String = "# x\n") {
    try! text.write(to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
}
write("a.md"); write("b.md"); write("c.md")

@MainActor
func run() async {
    let model = AppModel()
    model.openExternal([root])
    guard let source = model.sources.first(where: { $0.kind == .localFolder }) else {
        check("source added", false); return
    }
    func id(_ p: String) -> DocumentID { DocumentID(sourceID: source.id, path: p) }

    let w = WindowState()
    w.attach(model)
    // attach() may auto-open a default file; start from a known-empty strip.
    w.selection = nil
    w.openTabs = []

    // Sidebar browsing REUSES the current tab rather than piling up tabs.
    w.showInCurrentTab(id("a.md"))
    check("first file seeds a tab", w.openTabs == [id("a.md")])
    check("…and is active", w.selection == id("a.md"))

    w.showInCurrentTab(id("b.md"))
    check("browsing replaces the active tab in place", w.openTabs == [id("b.md")])
    check("…and shows the new file", w.selection == id("b.md"))

    // Explicit "open in new tab" is the way to actually add one.
    w.openInNewTab(id("c.md"))
    check("open-in-new-tab appends beside the active tab", w.openTabs == [id("b.md"), id("c.md")])
    check("…and activates it", w.selection == id("c.md"))

    w.showInCurrentTab(id("a.md"))
    check("browsing again replaces only the active tab", w.openTabs == [id("b.md"), id("a.md")])

    w.showInCurrentTab(id("b.md"))
    check("selecting an already-open file activates its tab", w.openTabs == [id("b.md"), id("a.md")])
    check("…without duplicating", w.selection == id("b.md"))

    w.openInNewTab(id("a.md"))
    check("open-in-new-tab on an open file just activates it", w.openTabs == [id("b.md"), id("a.md")])
    check("…and does not duplicate", w.selection == id("a.md"))

    // Build a known three-tab strip for the close tests.
    w.selection = nil
    w.openTabs = []
    w.openInNewTab(id("a.md"))
    w.openInNewTab(id("b.md"))
    w.openInNewTab(id("c.md"))
    check("three tabs open", w.openTabs == [id("a.md"), id("b.md"), id("c.md")])

    // Closing.
    w.closeTab(id("a.md"))
    check("closing an inactive tab removes it", w.openTabs == [id("b.md"), id("c.md")])
    check("…and leaves the active tab alone", w.selection == id("c.md"))

    w.closeTab(id("c.md"))
    check("closing the active tab removes it", w.openTabs == [id("b.md")])
    check("…and moves to the neighbour", w.selection == id("b.md"))

    w.closeTab(id("b.md"))
    check("closing the last tab empties the strip", w.openTabs.isEmpty)
    check("…and clears the editor", w.selection == nil)

    // Rename remaps an open tab in place.
    w.openInNewTab(id("a.md"))
    w.openInNewTab(id("b.md"))
    check("reopened two tabs", w.openTabs == [id("a.md"), id("b.md")])
    let renamed = await model.rename(id("a.md"), to: "renamed")
    check("rename produced the new id", renamed == id("renamed.md"), String(describing: renamed))
    check("the inactive tab remapped in place", w.openTabs == [id("renamed.md"), id("b.md")])
    check("…and the active tab was untouched", w.selection == id("b.md"))

    // Renaming the active file follows in both the tab and the selection.
    w.selection = id("renamed.md")
    _ = await model.rename(id("renamed.md"), to: "again")
    check("renaming the active file remaps its selection", w.selection == id("again.md"))
    check("…and its tab", w.openTabs == [id("again.md"), id("b.md")])

    // Deleting the active file drops its tab and falls back to a survivor.
    w.selection = nil
    w.openTabs = []
    let delName = "del-\(stamp).md"
    write(delName)
    w.selection = id("b.md")
    w.selection = id(delName)
    check("two tabs before the delete", w.openTabs == [id("b.md"), id(delName)])
    await model.delete(id(delName))
    check("deleting the active file drops its tab", w.openTabs == [id("b.md")])
    check("…and moves to the surviving tab", w.selection == id("b.md"))

    // Blank "New Tab": a fresh empty tab that a sidebar click then fills.
    w.selection = nil
    w.openTabs = []
    w.showInCurrentTab(id("b.md"))
    w.newBlankTab()
    check("New Tab adds a second tab", w.openTabs.count == 2)
    check("…that is blank", w.selection?.isBlankTab == true)
    check("…and inactive tab b is untouched", w.openTabs.first == id("b.md"))
    let blank = w.selection
    w.showInCurrentTab(id("c.md"))
    check("choosing a file fills the blank tab in place", w.openTabs == [id("b.md"), id("c.md")])
    check("…the blank tab is gone", w.openTabs.contains { $0.isBlankTab } == false)
    check("…blank id no longer active", w.selection == id("c.md") && w.selection != blank)

    // A blank tab closes like any other.
    w.newBlankTab()
    check("blank tab opened", w.selection?.isBlankTab == true)
    let blank2 = w.selection!
    w.closeTab(blank2)
    check("closing a blank tab removes it", w.openTabs.contains(blank2) == false)
    check("…and falls back to a file tab", w.selection?.isBlankTab == false)
}

await run()

// Clean up: only files this run uniquely named can be touched.
let trash = fm.urls(for: .trashDirectory, in: .userDomainMask).first
if let trash, let entries = try? fm.contentsOfDirectory(atPath: trash.path) {
    for entry in entries where entry.contains(stamp) {
        try? fm.removeItem(at: trash.appendingPathComponent(entry))
    }
}
try? fm.removeItem(at: root)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
