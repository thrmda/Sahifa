import Foundation
import Combine

/// One open .md file. Plain text on disk — no library, no database.
/// Autosaves one second after the last edit.
@MainActor
final class DocumentModel: ObservableObject, Identifiable {
    let url: URL
    @Published var text: String
    @Published private(set) var lastError: String?

    private var savedText: String
    private var cancellable: AnyCancellable?

    nonisolated var id: URL { url }

    var displayName: String {
        url.lastPathComponent
    }

    /// Suggested filename (sans extension) for exports.
    var exportName: String {
        url.deletingPathExtension().lastPathComponent
    }

    init(url: URL) {
        self.url = url
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        self.text = content
        self.savedText = content

        cancellable = $text
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveNow()
            }
    }

    func saveNow() {
        guard text != savedText else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
