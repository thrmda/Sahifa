import Combine
import Foundation
import SwiftUI

/// Per-window state: which document is selected, which folders are expanded,
/// and whether the preview pane is shown. Sources stay app-wide in AppModel;
/// documents come from its shared cache so two windows showing the same file
/// edit one DocumentModel instead of fighting over it.
@MainActor
final class WindowState: ObservableObject {

    @Published var selection: DocumentID? {
        didSet { openSelected() }
    }
    @Published private(set) var document: DocumentModel?
    /// Expansion is per window: two windows can browse the same tree at
    /// different depths, the same way each keeps its own document.
    @Published var expanded: Set<DocumentID> = []
    /// Per-window; the last change also becomes the default for new windows.
    @Published var showPreview: Bool {
        didSet { UserDefaults.standard.set(showPreview, forKey: "showPreview") }
    }
    @Published var sidebarVisible = true

    private weak var model: AppModel?
    private var observations: Set<AnyCancellable> = []

    init() {
        showPreview = UserDefaults.standard.bool(forKey: "showPreview")
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
                if !model.exists(selected) {
                    self.selection = model.defaultSelection
                }
            }
            .store(in: &observations)
        // A window sitting on nothing adopts a newly added folder; one with a
        // document open carries on.
        model.sourceAdded
            .sink { [weak self] source in
                guard let self, self.selection == nil else { return }
                let root = DocumentID(sourceID: source.id, path: "")
                self.expanded.insert(root)
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
        document = selection.flatMap { model?.document(for: $0) }
        if let selection { reveal(selection) }
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
