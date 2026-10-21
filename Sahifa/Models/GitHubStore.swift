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

    /// Built a component at a time so every piece is percent-encoded. Owner
    /// and repository are validated when the source is added (`parse`), but
    /// one interpolated into a string would turn a stray `?` or `#` into a
    /// query or a fragment and quietly address something else.
    private var repositoryURL: URL {
        var url = URL(string: "https://api.github.com/repos")!
        url.append(path: owner)
        url.append(path: repository)
        return url
    }

    private func endpoint(for id: DocumentID) -> URL {
        var url = repositoryURL.appending(path: "contents")
        if !id.path.isEmpty {
            for component in id.path.split(separator: "/") {
                url.append(path: String(component))
            }
        }
        guard let branch else { return url }
        url.append(queryItems: [URLQueryItem(name: "ref", value: branch)])
        return url
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
        if (200..<300).contains(http.statusCode) { return data }
        throw Self.error(for: http, body: data, writing: false)
    }

    /// One reading of GitHub's failures for every request, so a rate limit is
    /// never mistaken for a refused credential (which signs the account out)
    /// or for a missing permission (which stops retrying).
    static func error(for http: HTTPURLResponse, body: Data, writing: Bool) -> Error {
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message ?? ""
        let rateLimited = http.statusCode == 429
            || http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            || http.value(forHTTPHeaderField: "retry-after") != nil
            || message.localizedCaseInsensitiveContains("rate limit")
        switch http.statusCode {
        case 401:
            return RemoteStoreError.notAuthorised
        case 429, 403 where rateLimited:
            // (`where` binds only to the pattern beside it: 429 always counts.)
            return RemoteStoreError.rateLimited
        case 403:
            return writing ? RemoteStoreError.readOnly : RemoteStoreError.notAuthorised
        case 404:
            return RemoteStoreError.notFound
        case 409 where writing, 422 where writing:
            // A stale sha is a conflict the banner can settle. Anything else
            // here is GitHub refusing the change outright: a protected branch
            // that wants a pull request, a rule the commit breaks. Calling
            // that a conflict sent "Keep Mine" round the same refusal forever.
            let isStaleSha = message.localizedCaseInsensitiveContains("sha")
                || message.localizedCaseInsensitiveContains("but expected")
                || message.localizedCaseInsensitiveContains("does not match")
            if isStaleSha || message.isEmpty { return DocumentStoreError.versionConflict }
            return RemoteStoreError.rejected(message)
        default:
            return RemoteStoreError.server(status: http.statusCode)
        }
    }

    private struct ErrorBody: Decodable { let message: String }

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

    /// One folder's entries: subfolders, plus the files in it Sahifa opens.
    func children(of id: DocumentID) async throws -> [Node] {
        let data = try await fetch(endpoint(for: id))
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            // A file path returns an object rather than an array.
            throw RemoteStoreError.notADirectory
        }
        let nodes = entries.compactMap { entry -> Node? in
            let isDirectory = entry.type == "dir"
            guard isDirectory || DocumentKind(fileName: entry.name) != nil else { return nil }
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
        let (data, version) = try await readData(id)
        return DocumentContents(data: data, version: version)
    }

    /// The document's stored bytes, undecoded — what a move copies, so a file
    /// that isn't text Sahifa can decode still arrives intact.
    private func readData(_ id: DocumentID) async throws -> (Data, VersionToken) {
        let data = try await fetch(endpoint(for: id))
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        let version = VersionToken(raw: entry.sha)

        // Files over about a megabyte come back with the content omitted and
        // have to be fetched as a blob instead.
        if let encoded = entry.content, !encoded.isEmpty, entry.encoding == "base64" {
            return (try Self.decode(encoded), version)
        }
        return (try await readBlob(sha: entry.sha), version)
    }

    // MARK: Writing

    /// Sends the document back, quoting the sha it was read at. GitHub
    /// rejects the write if that sha is no longer current, which is the same
    /// question a local file answers with its modification date — so the
    /// conflict handling above it needs no special case for either.
    @discardableResult
    func write(_ text: String, to id: DocumentID,
               expecting: VersionToken?, encoding: TextEncoding) async throws -> VersionToken? {
        try await write(data: encoding.encode(text), to: id, expecting: expecting)
    }

    private func write(data: Data, to id: DocumentID,
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
            "content": data.base64EncodedString(),
        ]
        // Absent sha means "create"; GitHub refuses an update without one.
        if let expecting { body["sha"] = expecting.raw }
        if let branch { body["branch"] = branch }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteStoreError.server(status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http, body: data, writing: true)
        }
        struct Result: Decodable {
            struct Content: Decodable { let sha: String }
            let content: Content
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        return VersionToken(raw: result.content.sha)
    }

    func delete(_ id: DocumentID) async throws {
        guard let token, !token.isEmpty else { throw RemoteStoreError.readOnly }
        // GitHub needs the sha of exactly what is being removed.
        let current = try await read(id)
        guard let version = current.version else { throw RemoteStoreError.notFound }
        var request = URLRequest(url: endpoint(for: id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        var body: [String: Any] = ["message": "Delete \(id.name)", "sha": version.raw]
        if let branch { body["branch"] = branch }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteStoreError.server(status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(for: http, body: data, writing: true)
        }
    }

    /// The contents API has no rename, so a move is the document written at
    /// the new path and then removed from the old one. Deliberately in that
    /// order: if the second step fails the document still exists twice, which
    /// is recoverable, where the reverse order could lose it outright.
    func move(_ id: DocumentID, to destination: DocumentID) async throws {
        guard let token, !token.isEmpty else { throw RemoteStoreError.readOnly }
        // The bytes, not the decoded text: a file in an encoding Sahifa can't
        // decode would otherwise arrive at its new name as that lossy text.
        let (data, _) = try await readData(id)
        _ = try await write(data: data, to: destination, expecting: nil)
        try await delete(id)
    }

    private func readBlob(sha: String) async throws -> Data {
        let url = repositoryURL.appending(path: "git").appending(path: "blobs").appending(path: sha)
        let data = try await fetch(url)
        struct Blob: Decodable { let content: String; let encoding: String }
        let blob = try JSONDecoder().decode(Blob.self, from: data)
        guard blob.encoding == "base64" else { return Data(blob.content.utf8) }
        return try Self.decode(blob.content)
    }

    /// GitHub wraps its base64 at 60 columns, which Foundation rejects unless
    /// told to ignore the line breaks. A payload that still won't decode is a
    /// failed read, not an empty document — an empty one would be savable.
    private static func decode(_ encoded: String) throws -> Data {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
}

/// Failures a networked store can produce that a local folder simply cannot.
enum RemoteStoreError: LocalizedError {
    case readOnly
    case notFound
    case notAuthorised
    case rateLimited
    case notADirectory
    /// GitHub refused a change for a reason of its own, in its own words.
    case rejected(String)
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
        case .rejected(let message):
            return String(localized: "GitHub refused the change: \(message)")
        case .server(let status):
            return String(localized: "The server returned an error (\(status)).")
        }
    }
}

extension GitHubStore {
    /// Reads what someone typed or pasted as a repository: `owner/name`, or a
    /// github.com address, with or without `www.`, `.git`, a query, a
    /// fragment, or a deeper path such as `/tree/main`. nil when it doesn't
    /// name a repository GitHub could have: anything left over would end up
    /// in the request path and quietly ask for something else.
    static func parseRepository(_ input: String) -> (owner: String, name: String)? {
        var entry = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.contains("://") || entry.lowercased().hasPrefix("github.com/")
            || entry.lowercased().hasPrefix("www.github.com/") {
            let withScheme = entry.contains("://") ? entry : "https://" + entry
            guard let components = URLComponents(string: withScheme),
                  let host = components.host?.lowercased(),
                  host == "github.com" || host == "www.github.com"
            else { return nil }
            entry = components.path
        } else {
            // The short form can still carry a pasted fragment or query.
            entry = String(entry.prefix { $0 != "?" && $0 != "#" })
        }
        let parts = entry.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard isValidOwner(owner), isValidRepositoryName(name) else { return nil }
        return (owner, name)
    }

    /// GitHub account names: letters, digits and single hyphens.
    static func isValidOwner(_ owner: String) -> Bool {
        !owner.isEmpty && owner.count <= 39
            && owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Repository names: letters, digits, `.`, `-` and `_`, but never `.` or
    /// `..` on their own.
    static func isValidRepositoryName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 100 && name != "." && name != ".."
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
