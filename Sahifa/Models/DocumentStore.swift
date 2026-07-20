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

/// Reads and writes documents in one local folder.
///
/// Deliberately a concrete type rather than a protocol with one conformer:
/// the shape a remote store needs (async, cancellable, retrying, offline) is
/// better extracted from two real implementations than guessed from one. What
/// matters now is that `DocumentModel` no longer touches the file system, so
/// swapping in another store means changing this seam and not the document.
struct LocalFileStore: Sendable {
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

    func read(_ id: DocumentID) -> DocumentContents {
        let text = (try? String(contentsOf: url(for: id), encoding: .utf8)) ?? ""
        return DocumentContents(text: text, version: version(of: id))
    }

    /// Writes only when the document is still at `expecting`, so a file edited
    /// by another program is never silently overwritten. A document that has
    /// vanished counts as writable — recreating it keeps the user's text,
    /// which beats dropping it.
    @discardableResult
    func write(_ text: String, to id: DocumentID,
               expecting: VersionToken?) throws -> VersionToken? {
        if let current = version(of: id), current != expecting {
            throw DocumentStoreError.versionConflict
        }
        try text.write(to: url(for: id), atomically: true, encoding: .utf8)
        return version(of: id)
    }
}
