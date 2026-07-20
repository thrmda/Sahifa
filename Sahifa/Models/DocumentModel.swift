import Foundation
import Combine

/// One open .md file. Plain text on disk — no library, no database.
/// Autosaves one second after the last edit.
///
/// Because the file is plain text in a folder the user also reaches through
/// Finder, git and other editors, the document tracks what it last read or
/// wrote and refuses to autosave over a file that changed underneath it.
@MainActor
final class DocumentModel: ObservableObject, Identifiable {
    /// Source-scoped identity. `url` is how *this* (local) source happens to
    /// reach the document; a later source type would resolve `id` its own way,
    /// which is why nothing outside here keys off the URL.
    let id: DocumentID
    let url: URL
    @Published var text: String
    @Published private(set) var lastError: String?

    /// Set when the file changed on disk *and* this document has unsaved
    /// edits — the one case where neither version can be chosen automatically.
    /// Autosave stays paused until `resolveKeepingMine`/`resolveUsingDisk`.
    @Published private(set) var hasConflict = false

    private var savedText: String
    /// Identifies the file contents last read or written here. Anything else
    /// on disk means another program has been at it.
    private var diskStamp: DiskStamp?
    private var cancellable: AnyCancellable?

    var displayName: String {
        url.lastPathComponent
    }

    /// Suggested filename (sans extension) for exports.
    var exportName: String {
        url.deletingPathExtension().lastPathComponent
    }

    init(id: DocumentID, url: URL) {
        self.id = id
        self.url = url
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        self.text = content
        self.savedText = content
        self.diskStamp = DiskStamp(of: url)

        cancellable = $text
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveNow()
            }
    }

    func saveNow() {
        guard text != savedText, !hasConflict else { return }
        // A stamp we can read that doesn't match ours means someone wrote to
        // the file since. Writing now would destroy their version silently.
        // A stamp we *can't* read means the file is gone — writing recreates
        // it, which keeps the user's text rather than dropping it.
        if let current = DiskStamp(of: url), current != diskStamp {
            hasConflict = true
            return
        }
        write()
    }

    /// Picks up edits made by other programs. A document with nothing unsaved
    /// simply follows the file; one with unsaved edits raises a conflict
    /// rather than picking a winner on the user's behalf.
    func reconcileWithDisk() {
        guard let current = DiskStamp(of: url), current != diskStamp else { return }
        guard text == savedText else {
            hasConflict = true
            return
        }
        reloadFromDisk()
    }

    // MARK: Conflict resolution

    /// Keep what's in the editor, overwriting whatever is on disk.
    func resolveKeepingMine() {
        write()
    }

    /// Take the file's version, discarding unsaved edits in the editor.
    func resolveUsingDisk() {
        reloadFromDisk()
    }

    // MARK: Reading and writing

    private func write() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            diskStamp = DiskStamp(of: url)
            hasConflict = false
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadFromDisk() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Assigning `text` re-triggers the autosave debounce, but by then it
        // equals `savedText`, so the save is a no-op.
        text = content
        savedText = content
        diskStamp = DiskStamp(of: url)
        hasConflict = false
        lastError = nil
    }
}

/// A cheap fingerprint of a file's contents: modification date plus size.
/// Enough to notice another program's write without re-reading the file on
/// every autosave tick.
private struct DiskStamp: Equatable {
    let modified: Date
    let size: Int

    /// Reads through FileManager, NOT `URL.resourceValues`: a URL caches the
    /// resource values it has already fetched, so re-reading through the same
    /// URL keeps reporting the state from the first read and never notices
    /// another program's write.
    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        self.modified = modified
        self.size = size
    }
}
