import Combine
import Foundation

/// Per-window state: which file is selected and whether the preview pane is
/// shown. The workspace (folder, file list) stays app-wide in AppModel;
/// documents come from AppModel's shared cache so two windows showing the
/// same file edit one DocumentModel instead of fighting over the file.
@MainActor
final class WindowState: ObservableObject {

    @Published var selectedFile: URL? {
        didSet { openSelected() }
    }
    @Published private(set) var document: DocumentModel?
    /// Per-window; the last change also becomes the default for new windows.
    @Published var showPreview: Bool {
        didSet { UserDefaults.standard.set(showPreview, forKey: "showPreview") }
    }
    @Published var sidebarVisible = true

    private weak var model: AppModel?
    private var filesObservation: AnyCancellable?

    init() {
        showPreview = UserDefaults.standard.bool(forKey: "showPreview")
    }

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        if selectedFile == nil {
            // A Finder open during cold launch lands before any window exists.
            selectedFile = model.takePendingSelection() ?? model.defaultSelection
        }
        filesObservation = model.$files.sink { [weak self] files in
            guard let self else { return }
            if let selected = self.selectedFile, !files.contains(selected) {
                self.selectedFile = files.first
            } else if self.selectedFile == nil {
                self.selectedFile = files.first
            }
        }
    }

    private func openSelected() {
        guard document?.url != selectedFile else { return }
        document?.saveNow()
        document = selectedFile.flatMap { model?.document(for: $0) }
    }
}
