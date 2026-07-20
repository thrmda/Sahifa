import Foundation

/// Opaque marker for "which version of this document is on the other side".
///
/// Local files derive it from modification date and size. A repo would use a
/// blob SHA, a hosted wiki a revision id. Nothing compares the contents — the
/// only question anyone asks is whether it still equals the one we last read
/// or wrote, which is what makes overwrite detection portable.
struct VersionToken: Hashable, Sendable {
    let raw: String
}

struct DocumentContents: Sendable {
    let text: String
    /// Absent when the document doesn't exist yet.
    let version: VersionToken?
}

enum DocumentStoreError: Error {
    /// Someone else wrote to the document since we last read or wrote it.
    case versionConflict
}

/// Where a source's documents come from.
///
/// Extracted from two real implementations rather than guessed from one — the
/// split between `readImmediately` and `read` is the whole point. A local file
/// genuinely is available at once, and pretending otherwise would flash an
/// empty editor on every keystroke-fast document switch; anything fetched has
/// to be awaited. Callers take the fast path when there is one and show a
/// loading state when there isn't.
protocol DocumentStore: Sendable {
    /// True when documents can be browsed but not saved. Read-only is a real
    /// state, not a failure: a repository is readable long before writing to
    /// it has been set up.
    var isReadOnly: Bool { get }

    /// Contents available without waiting, or nil if the caller must `read`.
    func readImmediately(_ id: DocumentID) -> DocumentContents?
    func read(_ id: DocumentID) async throws -> DocumentContents
    func children(of id: DocumentID) async throws -> [Node]

    /// The version currently stored, when that can be answered without
    /// waiting. Remote stores return nil and answer during `read` instead.
    func versionImmediately(of id: DocumentID) -> VersionToken?

    /// Async because a networked store cannot answer synchronously. A local
    /// file still completes without ever suspending, so nothing waits on
    /// something that was already done.
    @discardableResult
    func write(_ text: String, to id: DocumentID,
               expecting: VersionToken?) async throws -> VersionToken?
}

/// Reads and writes documents in one local folder.
struct LocalFileStore: DocumentStore {
    let sourceID: UUID
    let root: URL

    func url(for id: DocumentID) -> URL {
        id.path.isEmpty ? root : root.appending(path: id.path)
    }

    /// Reads through FileManager, NOT `URL.resourceValues`: a URL caches the
    /// resource values it has already fetched, so re-reading through the same
    /// URL keeps reporting the state from the first read and never notices
    /// another program's write.
    func version(of id: DocumentID) -> VersionToken? {
        guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: url(for: id).path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return VersionToken(raw: "\(modified.timeIntervalSince1970):\(size)")
    }

    var isReadOnly: Bool { false }

    /// A local file is genuinely available at once, so both entry points
    /// resolve to the same synchronous read.
    func readImmediately(_ id: DocumentID) -> DocumentContents? {
        let text = (try? String(contentsOf: url(for: id), encoding: .utf8)) ?? ""
        return DocumentContents(text: text, version: version(of: id))
    }

    func read(_ id: DocumentID) async throws -> DocumentContents {
        readImmediately(id) ?? DocumentContents(text: "", version: nil)
    }

    func versionImmediately(of id: DocumentID) -> VersionToken? { version(of: id) }

    /// Folders and Markdown files in one directory, folders first, each group
    /// ordered the way Finder orders names.
    func childrenImmediately(of id: DocumentID) -> [Node] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url(for: id),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var nodes: [Node] = []
        for url in contents {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? url.hasDirectoryPath
            guard isDirectory || MarkdownFile.matches(url.lastPathComponent) else { continue }
            nodes.append(Node(id: id.appending(url.lastPathComponent),
                              name: url.lastPathComponent,
                              isDirectory: isDirectory))
        }
        return nodes.sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
    }

    func children(of id: DocumentID) async throws -> [Node] { childrenImmediately(of: id) }

    /// Writes only when the document is still at `expecting`, so a file edited
    /// by another program is never silently overwritten. A document that has
    /// vanished counts as writable — recreating it keeps the user's text,
    /// which beats dropping it.
    @discardableResult
    func write(_ text: String, to id: DocumentID,
               expecting: VersionToken?) async throws -> VersionToken? {
        if let current = version(of: id), current != expecting {
            throw DocumentStoreError.versionConflict
        }
        try text.write(to: url(for: id), atomically: true, encoding: .utf8)
        return version(of: id)
    }
}
