import Combine
import Foundation

/// One open document. Plain text on the other side of a store — no library,
/// no database. Autosaves one second after the last edit.
///
/// The document itself does no file I/O: it holds a `DocumentID`, a store to
/// reach it through, and the version it last read or wrote. That last piece
/// is what makes overwrite detection work, and it is deliberately opaque —
/// modification date and size for a local file today, a revision id for
/// anything fetched later, compared the same way either way.
@MainActor
final class DocumentModel: ObservableObject, Identifiable {
    let id: DocumentID
    @Published var text: String
    @Published private(set) var lastError: String?

    /// Set when the document changed underneath us *and* there are unsaved
    /// edits — the one case where neither version can be chosen automatically.
    /// Autosave stays paused until `resolveKeepingMine`/`resolveUsingDisk`.
    @Published private(set) var hasConflict = false

    private let store: LocalFileStore
    private var savedText: String
    private var version: VersionToken?
    private var cancellable: AnyCancellable?

    var displayName: String { id.name }

    /// Suggested filename (sans extension) for exports.
    var exportName: String { (id.name as NSString).deletingPathExtension }

    init(id: DocumentID, store: LocalFileStore) {
        self.id = id
        self.store = store
        let contents = store.read(id)
        self.text = contents.text
        self.savedText = contents.text
        self.version = contents.version

        cancellable = $text
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveNow()
            }
    }

    func saveNow() {
        guard text != savedText, !hasConflict else { return }
        write()
    }

    /// Picks up edits made by other programs. A document with nothing unsaved
    /// simply follows the file; one with unsaved edits raises a conflict
    /// rather than picking a winner on the user's behalf.
    func reconcileWithDisk() {
        guard let current = store.version(of: id), current != version else { return }
        guard text == savedText else {
            hasConflict = true
            return
        }
        reload()
    }

    // MARK: Conflict resolution

    /// Keep what's in the editor, overwriting whatever is stored.
    func resolveKeepingMine() {
        version = store.version(of: id)   // accept their version as the base
        write()
    }

    /// Take the stored version, discarding unsaved edits in the editor.
    func resolveUsingDisk() {
        reload()
    }

    // MARK: Reading and writing

    private func write() {
        do {
            version = try store.write(text, to: id, expecting: version)
            savedText = text
            hasConflict = false
            lastError = nil
        } catch DocumentStoreError.versionConflict {
            hasConflict = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reload() {
        let contents = store.read(id)
        // Assigning `text` re-triggers the autosave debounce, but by then it
        // equals `savedText`, so the save is a no-op.
        text = contents.text
        savedText = contents.text
        version = contents.version
        hasConflict = false
        lastError = nil
    }
}
