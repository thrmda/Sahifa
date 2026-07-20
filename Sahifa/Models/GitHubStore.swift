import Foundation

/// Reads Markdown out of a GitHub repository.
///
/// The repository contents API happens to match what the sidebar already
/// does: asking for a folder returns just that folder's entries, which is one
/// request per folder opened rather than a walk of the whole repository. Each
/// entry carries a `sha`, and that is the version marker — the same role the
/// modification date plays for a local file.
///
/// Read-only for now. Writing uses the same endpoint with the sha attached,
/// which is where the conflict handling already built will slot in.
struct GitHubStore: DocumentStore {
    let sourceID: UUID
    let owner: String
    let repository: String
    /// nil uses the repository's default branch.
    let branch: String?
    /// nil reads anonymously, which works for public repositories.
    let token: String?

    /// Without a credential a repository can still be browsed, but not
    /// written to. Whether the credential actually grants write access can
    /// only be discovered by trying — GitHub answers that with a 403.
    var isReadOnly: Bool { token == nil }

    func readImmediately(_ id: DocumentID) -> DocumentContents? { nil }
    func versionImmediately(of id: DocumentID) -> VersionToken? { nil }

    var displayName: String { "\(owner)/\(repository)" }

    // MARK: Requests

    private var base: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/contents")!
    }

    private func endpoint(for id: DocumentID) -> URL {
        var url = base
        if !id.path.isEmpty {
            for component in id.path.split(separator: "/") {
                url.append(path: String(component))
            }
        }
        guard let branch else { return url }
        return URL(string: url.absoluteString + "?ref=\(branch)") ?? url
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        // URLSession caches GET responses, and GitHub's contents endpoint is
        // cacheable — so a read taken just after a save was being answered
        // from the local cache with the *previous* version of the document.
        // Always go to the server; correctness matters more here than a
        // request saved.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw RemoteStoreError.notAuthorised
        case 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            throw RemoteStoreError.rateLimited
        case 403:
            throw RemoteStoreError.notAuthorised
        case 404:
            throw RemoteStoreError.notFound
        default:
            throw RemoteStoreError.server(status: http.statusCode)
        }
    }

    // MARK: Reading

    private struct Entry: Decodable {
        let name: String
        let path: String
        let type: String
        let sha: String
        let size: Int?
        let content: String?
        let encoding: String?
    }

    /// One folder's entries: subfolders, plus the Markdown files in it.
    func children(of id: DocumentID) async throws -> [Node] {
        let data = try await fetch(endpoint(for: id))
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            // A file path returns an object rather than an array.
            throw RemoteStoreError.notADirectory
        }
        let nodes = entries.compactMap { entry -> Node? in
            let isDirectory = entry.type == "dir"
            guard isDirectory || MarkdownFile.matches(entry.name) else { return nil }
            return Node(id: DocumentID(sourceID: sourceID, path: entry.path),
                        name: entry.name,
                        isDirectory: isDirectory)
        }
        return nodes.sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
    }

    func read(_ id: DocumentID) async throws -> DocumentContents {
        let data = try await fetch(endpoint(for: id))
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        let version = VersionToken(raw: entry.sha)

        // Files over about a megabyte come back with the content omitted and
        // have to be fetched as a blob instead.
        if let encoded = entry.content, !encoded.isEmpty, entry.encoding == "base64" {
            return DocumentContents(text: Self.decode(encoded), version: version)
        }
        return DocumentContents(text: try await readBlob(sha: entry.sha), version: version)
    }

    // MARK: Writing

    /// Sends the document back, quoting the sha it was read at. GitHub
    /// rejects the write if that sha is no longer current, which is the same
    /// question a local file answers with its modification date — so the
    /// conflict handling above it needs no special case for either.
    @discardableResult
    func write(_ text: String, to id: DocumentID,
               expecting: VersionToken?) async throws -> VersionToken? {
        guard let token, !token.isEmpty else { throw RemoteStoreError.readOnly }
        var request = URLRequest(url: endpoint(for: id))
        request.httpMethod = "PUT"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "message": "Update \(id.name)",
            "content": Data(text.utf8).base64EncodedString(),
        ]
        // Absent sha means "create"; GitHub refuses an update without one.
        if let expecting { body["sha"] = expecting.raw }
        if let branch { body["branch"] = branch }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteStoreError.server(status: 0)
        }
        switch http.statusCode {
        case 200..<300:
            struct Result: Decodable {
                struct Content: Decodable { let sha: String }
                let content: Content
            }
            let result = try JSONDecoder().decode(Result.self, from: data)
            return VersionToken(raw: result.content.sha)
        case 409, 422:
            // 409 is an outright conflict; 422 is what GitHub returns when the
            // sha quoted is stale. Both mean the same thing to the caller.
            throw DocumentStoreError.versionConflict
        case 401:
            throw RemoteStoreError.notAuthorised
        case 403:
            throw RemoteStoreError.readOnly
        case 404:
            throw RemoteStoreError.notFound
        default:
            throw RemoteStoreError.server(status: http.statusCode)
        }
    }

    private func readBlob(sha: String) async throws -> String {
        let url = URL(string:
            "https://api.github.com/repos/\(owner)/\(repository)/git/blobs/\(sha)")!
        let data = try await fetch(url)
        struct Blob: Decodable { let content: String; let encoding: String }
        let blob = try JSONDecoder().decode(Blob.self, from: data)
        guard blob.encoding == "base64" else { return blob.content }
        return Self.decode(blob.content)
    }

    /// GitHub wraps its base64 at 60 columns, which Foundation rejects unless
    /// told to ignore the line breaks.
    private static func decode(_ encoded: String) -> String {
        guard let data = Data(base64Encoded: encoded,
                              options: .ignoreUnknownCharacters) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Failures a networked store can produce that a local folder simply cannot.
enum RemoteStoreError: LocalizedError {
    case readOnly
    case notFound
    case notAuthorised
    case rateLimited
    case notADirectory
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .readOnly:
            return String(localized: "This account can't write to that repository.")
        case .notFound:
            return String(localized: "Not found on the server.")
        case .notAuthorised:
            return String(localized: "Access was refused. Check the account or token.")
        case .rateLimited:
            return String(localized: "GitHub's request limit was reached. Try again shortly.")
        case .notADirectory:
            return String(localized: "That path is not a folder.")
        case .server(let status):
            return String(localized: "The server returned an error (\(status)).")
        }
    }
}
