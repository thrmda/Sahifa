import Foundation

/// Identifies a document *within a source*, rather than by file URL.
///
/// A URL can only name something on this Mac. Every later source — a repo, a
/// hosted wiki — addresses its documents by its own scheme, so selection,
/// the document cache and the sidebar all key off this instead. While every
/// source is a local folder the two are interchangeable; the point is that
/// nothing outside `Source` gets to assume that.
struct DocumentID: Hashable, Codable {
    let sourceID: UUID
    /// Path relative to the source's root. Empty string is the root itself.
    let path: String

    var name: String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    func appending(_ component: String) -> DocumentID {
        DocumentID(sourceID: sourceID,
                   path: path.isEmpty ? component : "\(path)/\(component)")
    }

    var parent: DocumentID? {
        guard !path.isEmpty else { return nil }
        return DocumentID(sourceID: sourceID,
                          path: (path as NSString).deletingLastPathComponent)
    }

    /// True when this is `other`, or lives inside it. Renaming a folder has to
    /// find everything underneath it.
    func isWithin(_ other: DocumentID) -> Bool {
        guard sourceID == other.sourceID else { return false }
        if other.path.isEmpty { return true }
        return path == other.path || path.hasPrefix(other.path + "/")
    }

    /// Rewrites this ID as though `from` had been renamed to `to`. Returns nil
    /// when this ID isn't affected.
    func remapping(from: DocumentID, to: DocumentID) -> DocumentID? {
        guard isWithin(from) else { return nil }
        if path == from.path { return to }
        let suffix = path.dropFirst(from.path.isEmpty ? 0 : from.path.count + 1)
        return DocumentID(sourceID: to.sourceID,
                          path: to.path.isEmpty ? String(suffix) : "\(to.path)/\(suffix)")
    }
}

/// A root the user has added: today always a local folder, plus the one
/// built-in `looseFiles` source that holds documents opened on their own.
///
/// `kind` exists so the sidebar can already branch on source type — the
/// remote cases slot in beside `localFolder` without the surrounding code
/// learning anything new.
struct Source: Identifiable, Hashable {
    enum Kind: String, Codable {
        case localFolder
        /// Files opened individually that live outside every added folder.
        /// Under the sandbox their parent folder is usually unreadable, so
        /// they genuinely have nowhere else to go.
        case looseFiles
        /// A GitHub repository, read over the network.
        case gitHub
    }

    /// Which repository a `.gitHub` source points at.
    struct Repository: Hashable, Codable {
        let owner: String
        let name: String
        /// nil follows the repository's default branch.
        var branch: String?
    }

    enum Status: Hashable {
        case ready
        /// Resolved, but the folder is gone (moved, renamed, unmounted).
        case missing
        /// The credential was refused: expired, revoked, or its access to this
        /// repository withdrawn.
        case needsSignIn
    }

    let id: UUID
    let kind: Kind
    var name: String
    /// Where a local source lives. Remote sources have no folder on this Mac.
    var rootURL: URL?
    var repository: Repository?
    var status: Status = .ready

    /// Fixed so the loose-files source keeps its identity across launches.
    static let looseFilesID = UUID(uuidString: "5A417FA0-0000-4000-A000-000000000001")!

    static func looseFiles() -> Source {
        Source(id: looseFilesID, kind: .looseFiles,
               name: String(localized: "Opened Files"),
               rootURL: URL(fileURLWithPath: "/"))
    }

    /// Nothing outside a store should reach for a path; this exists for the
    /// few local-only affordances (Reveal in Finder, the folder watcher).
    var isLocal: Bool { kind == .localFolder || kind == .looseFiles }

    var isLooseFiles: Bool { kind == .looseFiles }

    /// Resolves a document in this source to a file URL, when there is one.
    func url(for id: DocumentID) -> URL? {
        guard let rootURL else { return nil }
        return id.path.isEmpty ? rootURL : rootURL.appending(path: id.path)
    }

    func documentID(for url: URL) -> DocumentID? {
        guard let rootURL else { return nil }
        let root = rootURL.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        if kind == .looseFiles {
            // Root is "/", so every absolute path is expressible; membership
            // is decided by the explicit file list, not by prefix.
            return DocumentID(sourceID: id, path: String(target.dropFirst()))
        }
        guard target == root else {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard target.hasPrefix(prefix) else { return nil }
            return DocumentID(sourceID: id, path: String(target.dropFirst(prefix.count)))
        }
        return DocumentID(sourceID: id, path: "")
    }
}

/// What kind of document a file is, decided by its extension. Lives here
/// rather than on AppModel so a store can decide what to list without reaching
/// for app state. Matches the types declared in `Sahifa-Info.plist`; keep the
/// two in step.
enum DocumentKind: Equatable, Sendable {
    case markdown
    /// CSV. The delimiter is detected from the text rather than assumed: a
    /// `.csv` exported where decimals are written with a comma is
    /// semicolon-separated.
    case delimited
    /// Tab-separated, whatever it contains.
    case tabSeparated

    static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    static let delimitedExtensions = ["csv"]
    static let tabSeparatedExtensions = ["tsv", "tab"]
    /// Everything the sidebar lists and the Open panel accepts.
    static let openableExtensions = markdownExtensions + delimitedExtensions + tabSeparatedExtensions

    /// nil for a file Sahifa doesn't open.
    init?(fileName: String) {
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        if Self.markdownExtensions.contains(pathExtension) {
            self = .markdown
        } else if Self.delimitedExtensions.contains(pathExtension) {
            self = .delimited
        } else if Self.tabSeparatedExtensions.contains(pathExtension) {
            self = .tabSeparated
        } else {
            return nil
        }
    }

    /// Shown as a table rather than rendered as Markdown.
    var isTable: Bool { self != .markdown }
}

extension DocumentID {
    var kind: DocumentKind? { DocumentKind(fileName: name) }
}

/// One row in the sidebar tree.
struct Node: Identifiable, Hashable {
    let id: DocumentID
    let name: String
    let isDirectory: Bool
}
