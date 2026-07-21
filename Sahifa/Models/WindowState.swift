import Combine
import Foundation
import SwiftUI

/// How the document area is divided between the editor and the rendered
/// preview. `split` shows both side by side; the other two give one pane the
/// whole width.
enum ViewMode: String, CaseIterable {
    case editOnly
    case split
    case previewOnly

    var showsEditor: Bool { self != .previewOnly }
    var showsPreview: Bool { self != .editOnly }
}

extension DocumentID {
    /// A reserved source id used only for blank "New Tab" placeholders. No real
    /// source ever uses it, so `store(for:)`/`document(for:)` return nil and the
    /// tab shows the empty state until a file is chosen into it.
    private static let blankTabSourceID = UUID(uuidString: "5A417FA0-0000-4000-A000-0000000000B1")!

    /// A fresh blank tab. The random path keeps two blank tabs distinct.
    static func blankTab() -> DocumentID {
        DocumentID(sourceID: blankTabSourceID, path: UUID().uuidString)
    }

    var isBlankTab: Bool { sourceID == DocumentID.blankTabSourceID }
}

/// Per-window state: which document is selected, which folders are expanded,
/// and how the editor/preview panes are laid out. Sources stay app-wide in
/// AppModel; documents come from its shared cache so two windows showing the
/// same file edit one DocumentModel instead of fighting over it.
@MainActor
final class WindowState: ObservableObject {

    @Published var selection: DocumentID? {
        didSet { openSelected() }
    }
    @Published private(set) var document: DocumentModel?
    /// Expansion is per window: two windows can browse the same tree at
    /// different depths, the same way each keeps its own document.
    @Published var expanded: Set<DocumentID> = []
    /// The row currently being renamed inline, and the text being edited.
    @Published var renaming: DocumentID?
    @Published var renameText = ""
    /// Per-window; the last change also becomes the default for new windows.
    @Published var viewMode: ViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    /// Files open as tabs in THIS window, in the order they were opened; the
    /// active tab is `selection`. These are lightweight in-window tabs (one
    /// shared sidebar, instant switching, no new windows) — distinct from the
    /// native window-tabs used for deliberate side-by-side work.
    @Published var openTabs: [DocumentID] = []
    @Published var sidebarVisible = true

    private weak var model: AppModel?
    private var observations: Set<AnyCancellable> = []

    init() {
        // Carry forward the old boolean preference: a shown preview was the
        // side-by-side split, a hidden one was editor-only.
        if let raw = UserDefaults.standard.string(forKey: "viewMode"),
           let mode = ViewMode(rawValue: raw) {
            viewMode = mode
        } else {
            viewMode = UserDefaults.standard.bool(forKey: "showPreview") ? .split : .editOnly
        }
    }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // Source roots open by default — a sidebar of collapsed folder names
        // reads as an empty app on launch.
        for source in model.sources {
            expanded.insert(DocumentID(sourceID: source.id, path: ""))
        }
        if selection == nil {
            // A Finder open during cold launch lands before any window exists.
            selection = model.takePendingSelection() ?? model.defaultSelection
        }
        // A window gives up its document only when it genuinely disappears —
        // not merely because the tree was re-read. Adding a source or opening
        // a file elsewhere must never pull a window off what it is showing.
        model.$childrenByDirectory
            .sink { [weak self] _ in
                guard let self, let selected = self.selection else { return }
                // Only a real local file can vanish out from under us this way.
                // A blank "New Tab" and a remote (GitHub) file both fail exists()
                // by nature — dropping them here would wrongly yank the window
                // off an empty tab or a repo file every time the tree reloads.
                guard !selected.isBlankTab,
                      model.source(selected.sourceID)?.isLocal == true,
                      !model.exists(selected) else { return }
                self.closeTab(selected)
            }
            .store(in: &observations)
        // A rename moves every ID underneath it, so each window rewrites its
        // own selection and open folders rather than losing its place.
        model.documentMoved
            .sink { [weak self] move in
                guard let self else { return }
                // Where the active file sat before the list is rewritten, so a
                // delete can fall back to the neighbouring tab rather than
                // jumping to some unrelated default.
                let activeIndex = self.selection.flatMap { self.openTabs.firstIndex(of: $0) }
                // A rename remaps each affected tab in place; a delete
                // (move.to == nil) drops it.
                self.openTabs = self.openTabs.compactMap { id in
                    guard id.isWithin(move.from) else { return id }
                    return move.to.flatMap { id.remapping(from: move.from, to: $0) }
                }
                if let selection = self.selection, selection.isWithin(move.from) {
                    if let to = move.to {
                        self.selection = selection.remapping(from: move.from, to: to)
                            ?? model.defaultSelection
                    } else if !self.openTabs.isEmpty {
                        self.selection = self.openTabs[min(activeIndex ?? 0, self.openTabs.count - 1)]
                    } else {
                        self.selection = model.defaultSelection
                    }
                }
                self.expanded = Set(self.expanded.compactMap { id in
                    guard id.isWithin(move.from) else { return id }
                    return move.to.flatMap { id.remapping(from: move.from, to: $0) }
                })
            }
            .store(in: &observations)
        // A newly added source always opens. Leaving it collapsed made adding
        // one look like nothing had happened — the row appears at the bottom
        // of the list showing only its name, while a repository quietly
        // fetches behind it. Expanded, it shows its contents arriving.
        // Selection is a separate question: a window already showing a
        // document keeps it.
        model.sourceAdded
            .sink { [weak self] source in
                guard let self else { return }
                let root = DocumentID(sourceID: source.id, path: "")
                self.expanded.insert(root)
                guard self.selection == nil else { return }
                self.selection = model.children(of: root)?.first { !$0.isDirectory }?.id
            }
            .store(in: &observations)
    }

    /// Where a new file should land: the selected folder, or the folder
    /// holding the selected document, so ⌘N follows what the user is looking
    /// at rather than always dropping into the first source.
    var newFileTarget: DocumentID? {
        guard let selection else { return nil }
        if model?.children(of: selection) != nil { return selection }
        let parent = (selection.path as NSString).deletingLastPathComponent
        return DocumentID(sourceID: selection.sourceID, path: parent)
    }

    /// Drives a DisclosureGroup and loads that directory's children the first
    /// time it opens — this is where lazy loading is actually triggered.
    func expansionBinding(for id: DocumentID) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    self.expanded.insert(id)
                    self.model?.loadChildren(of: id)
                } else {
                    self.expanded.remove(id)
                }
            }
        )
    }

    private func openSelected() {
        guard document?.id != selection else { return }
        document?.saveNow()
        // Safety net so the active file always has a tab. Deliberate opens go
        // through showInCurrentTab/openInNewTab; this only catches selections
        // set by other paths — the launch default, or a fallback after the
        // shown file was renamed or deleted out from under the window.
        if let selection, !openTabs.contains(selection) {
            openTabs.append(selection)
        }
        document = selection.flatMap { model?.document(for: $0) }
        // A blank tab has no place in the tree to reveal.
        if let selection, !selection.isBlankTab { reveal(selection) }
    }

    /// The everyday sidebar click: show a file in the CURRENT tab. If it is
    /// already open, just activate that tab; otherwise the active tab navigates
    /// to it in place — so browsing the tree reuses one tab instead of piling
    /// them up. Opening a genuinely new tab is a separate, explicit action
    /// (`openInNewTab`).
    func showInCurrentTab(_ id: DocumentID) {
        guard selection != id else { return }
        if !openTabs.contains(id),
           let active = selection,
           let index = openTabs.firstIndex(of: active) {
            openTabs[index] = id
        }
        // If nothing is open yet, openSelected() seeds the first tab.
        selection = id
    }

    /// Opens a fresh empty tab beside the active one (⌘T, the tab bar's +). It
    /// shows the empty state until a sidebar click fills it — browser-style.
    func newBlankTab() {
        let blank = DocumentID.blankTab()
        let insertAt = selection.flatMap { openTabs.firstIndex(of: $0) }
            .map { $0 + 1 } ?? openTabs.count
        openTabs.insert(blank, at: insertAt)
        selection = blank
    }

    /// Opens a file in a NEW tab beside the active one — Open File…, the
    /// sidebar's "Open in New Tab", Finder, drag-drop. A file already open just
    /// gets activated rather than duplicated.
    func openInNewTab(_ id: DocumentID) {
        guard !openTabs.contains(id) else { selection = id; return }
        let insertAt = selection.flatMap { openTabs.firstIndex(of: $0) }
            .map { $0 + 1 } ?? openTabs.count
        openTabs.insert(id, at: insertAt)
        selection = id
    }

    /// Closes one tab. Closing the active tab moves to its neighbour so the
    /// editor keeps showing a file while others are still open; closing the
    /// last one clears the editor back to the empty state.
    func closeTab(_ id: DocumentID) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        if selection == id { document?.saveNow() }
        openTabs.remove(at: index)
        guard selection == id else { return }
        selection = openTabs.isEmpty ? nil : openTabs[min(index, openTabs.count - 1)]
    }

    /// Opens every folder above a document so a file opened from Finder or the
    /// Open Recent menu is actually visible in the tree, not buried.
    private func reveal(_ id: DocumentID) {
        var current = DocumentID(sourceID: id.sourceID, path: "")
        expanded.insert(current)
        model?.loadChildren(of: current)
        for component in id.path.split(separator: "/").dropLast() {
            current = current.appending(String(component))
            expanded.insert(current)
            model?.loadChildren(of: current)
        }
    }
}
