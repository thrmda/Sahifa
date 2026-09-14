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
    /// How to turn the text back into bytes. nil when the stored bytes aren't
    /// text Sahifa can write back faithfully: `text` is then only a lossy
    /// rendering for display, and saving it would destroy every character it
    /// couldn't read.
    let encoding: TextEncoding?
    /// The stored bytes, kept only when they couldn't be decoded, so the
    /// document can be reopened in an encoding the user names without reading
    /// it again. nil for a file that couldn't be read at all.
    let undecodedData: Data?

    init(text: String, version: VersionToken?, encoding: TextEncoding? = .utf8) {
        self.text = text
        self.version = version
        self.encoding = encoding
        self.undecodedData = nil
    }

    init(data: Data, version: VersionToken?) {
        self.version = version
        if let decoded = TextEncoding.decode(data) {
            self.text = decoded.text
            self.encoding = decoded.encoding
            self.undecodedData = nil
        } else {
            self.text = String(decoding: data, as: UTF8.self)
            self.encoding = nil
            self.undecodedData = data
        }
    }
}

/// The Unicode encodings a document can be read in and written back in, byte
/// for byte. Anything else — a Windows-1256 export, say — has no case here on
/// purpose: guessing a legacy encoding and converting it on save would rewrite
/// someone's file in an encoding they didn't choose.
enum TextEncoding: Hashable, Sendable {
    case utf8
    /// Kept rather than dropped on save: Excel only reads a UTF-8 CSV as
    /// UTF-8 when the mark is there, and shows Arabic as garbage without it.
    case utf8WithBOM
    case utf16LittleEndian
    case utf16BigEndian

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Strict: the bytes must be valid UTF-8, or UTF-16 behind a byte-order
    /// mark. Foundation's own UTF-8 reading can't be used for this — it
    /// silently strips a BOM, so the file would lose it on the next save.
    static func decode(_ data: Data) -> (text: String, encoding: TextEncoding)? {
        let bytes = [UInt8](data)
        // UTF-32 marks begin with the UTF-16 ones, so rule them out first.
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return nil
        }
        if bytes.starts(with: utf8BOM) {
            return utf8(bytes.dropFirst(3)).map { ($0, .utf8WithBOM) }
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return utf16(bytes.dropFirst(2), bigEndian: false).map { ($0, .utf16LittleEndian) }
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return utf16(bytes.dropFirst(2), bigEndian: true).map { ($0, .utf16BigEndian) }
        }
        return utf8(bytes[...]).map { ($0, .utf8) }
    }

    func encode(_ text: String) -> Data {
        switch self {
        case .utf8:
            return Data(text.utf8)
        case .utf8WithBOM:
            return Data(Self.utf8BOM + Array(text.utf8))
        case .utf16LittleEndian:
            return Data([0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        case .utf16BigEndian:
            return Data([0xFE, 0xFF] + text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        }
    }

    /// Arabic (Windows-1256): what Excel on an Arabic Windows machine writes
    /// for a plain "CSV". Never guessed — only tried when someone asks for it,
    /// since almost any bytes decode as something in a single-byte encoding.
    static func decodeWindows1256(_ data: Data) -> String? {
        let arabic = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsArabic.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: arabic))
    }

    /// Decoding replaces anything invalid with U+FFFD, so the bytes were valid
    /// exactly when re-encoding the result gives them back.
    private static func utf8(_ bytes: ArraySlice<UInt8>) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) ? text : nil
    }

    private static func utf16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        let text = String(decoding: units, as: UTF16.self)
        return text.utf16.elementsEqual(units) ? text : nil
    }
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
    ///
    /// A nil `expecting` means "this should not exist yet", which is how a
    /// document is created. `encoding` is the one the document was read in,
    /// so a save never changes a file's encoding or drops its byte-order mark.
    @discardableResult
    func write(_ text: String, to id: DocumentID,
               expecting: VersionToken?, encoding: TextEncoding) async throws -> VersionToken?

    func delete(_ id: DocumentID) async throws

    /// Moves a document, and everything under it when it's a folder.
    func move(_ id: DocumentID, to destination: DocumentID) async throws
}

extension DocumentStore {
    /// Creating, renaming and deleting all require writing, so one flag
    /// governs the lot rather than each affordance guessing separately.
    var canOrganise: Bool { !isReadOnly }

    /// With no existing encoding to keep — creating a document — text is
    /// written as plain UTF-8.
    @discardableResult
    func write(_ text: String, to id: DocumentID,
               expecting: VersionToken?) async throws -> VersionToken? {
        try await write(text, to: id, expecting: expecting, encoding: .utf8)
    }
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
        let version = version(of: id)
        guard let data = try? Data(contentsOf: url(for: id)) else {
            // Absent is a document yet to be written. Present but unreadable
            // (no permission, say) must not come back as an empty, savable
            // document — the first autosave would replace the file.
            return DocumentContents(text: "", version: version,
                                    encoding: version == nil ? .utf8 : nil)
        }
        return DocumentContents(data: data, version: version)
    }

    func read(_ id: DocumentID) async throws -> DocumentContents {
        readImmediately(id) ?? DocumentContents(text: "", version: nil)
    }

    func versionImmediately(of id: DocumentID) -> VersionToken? { version(of: id) }

    /// Folders and the files Sahifa opens in one directory, folders first, each group
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
            guard isDirectory || DocumentKind(fileName: url.lastPathComponent) != nil else { continue }
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
               expecting: VersionToken?, encoding: TextEncoding) async throws -> VersionToken? {
        if let current = version(of: id), current != expecting {
            throw DocumentStoreError.versionConflict
        }
        try encoding.encode(text).write(to: url(for: id), options: .atomic)
        return version(of: id)
    }

    /// The Trash rather than an unlink: recoverable, and what a Mac user
    /// expects a delete to mean for a file on their own disk.
    func delete(_ id: DocumentID) async throws {
        try FileManager.default.trashItem(at: url(for: id), resultingItemURL: nil)
    }

    func move(_ id: DocumentID, to destination: DocumentID) async throws {
        try FileManager.default.moveItem(at: url(for: id), to: url(for: destination))
    }
}
