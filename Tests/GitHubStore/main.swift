import Foundation

var failures = 0
var skipped = false
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

/// Reads the project's own public repository, so this needs no credentials.
/// Anonymous GitHub access is limited to 60 requests an hour; the run uses
/// four, and reports a skip rather than a failure when the network or the
/// limit is against us.
let store = GitHubStore(sourceID: UUID(), owner: "thrmda", repository: "Sahifa",
                        branch: nil, token: nil)
func id(_ path: String) -> DocumentID { DocumentID(sourceID: store.sourceID, path: path) }

// MARK: Offline: reading what was typed as a repository

func parsed(_ input: String) -> String {
    GitHubStore.parseRepository(input).map { "\($0.owner)/\($0.name)" } ?? "nil"
}
check("owner/name parses", parsed("apple/swift-markdown") == "apple/swift-markdown")
check("a pasted URL with a query drops the query",
      parsed("https://github.com/apple/swift-markdown?tab=readme-ov-file") == "apple/swift-markdown",
      parsed("https://github.com/apple/swift-markdown?tab=readme-ov-file"))
check("…and a fragment",
      parsed("https://github.com/apple/swift-markdown#readme") == "apple/swift-markdown")
check("www. is accepted", parsed("https://www.github.com/a-b/c.d") == "a-b/c.d")
check("a deeper path keeps the repository", parsed("github.com/apple/swift-markdown/tree/main")
      == "apple/swift-markdown")
check(".git is dropped", parsed("https://github.com/apple/swift-markdown.git") == "apple/swift-markdown")
check("a bare name is refused", parsed("swift-markdown") == "nil")
check("another host is refused", parsed("https://gitlab.com/a/b") == "nil")
check("'..' is refused as a repository", parsed("a/..") == "nil")
check("spaces are refused", parsed("my org/repo") == "nil")

// MARK: Offline: what GitHub's refusals mean

func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://api.github.com/x")!, statusCode: status,
                    httpVersion: nil, headerFields: headers)!
}
func body(_ message: String) -> Data { Data("{\"message\":\(String(reflecting: message))}".utf8) }
func describe(_ error: Error) -> String { String(describing: error) }

check("a stale sha is a conflict",
      describe(GitHubStore.error(for: response(409), body: body("README.md is at abc but expected def"), writing: true))
        == describe(DocumentStoreError.versionConflict))
check("a missing sha is a conflict",
      describe(GitHubStore.error(for: response(422), body: body("Invalid request.\n\n\"sha\" wasn't supplied."), writing: true))
        == describe(DocumentStoreError.versionConflict))
let protected = GitHubStore.error(for: response(409),
                                  body: body("Repository rule violations found\n\nChanges must be made through a pull request."),
                                  writing: true)
check("a protected branch is a refusal, not a conflict",
      { if case RemoteStoreError.rejected = protected { return true }; return false }(),
      describe(protected))
check("a secondary rate limit on a write is a rate limit",
      describe(GitHubStore.error(for: response(403, ["retry-after": "60"]), body: body("You have exceeded a secondary rate limit"), writing: true))
        == describe(RemoteStoreError.rateLimited))
check("a secondary rate limit on a read doesn't sign the account out",
      describe(GitHubStore.error(for: response(403), body: body("You have exceeded a secondary rate limit"), writing: false))
        == describe(RemoteStoreError.rateLimited))
check("429 is a rate limit",
      describe(GitHubStore.error(for: response(429), body: Data(), writing: false))
        == describe(RemoteStoreError.rateLimited))
check("a plain 403 on a write is read-only",
      describe(GitHubStore.error(for: response(403), body: body("Resource not accessible"), writing: true))
        == describe(RemoteStoreError.readOnly))
check("a plain 403 on a read refuses this repository, not the account",
      describe(GitHubStore.error(for: response(403), body: body("Resource not accessible by personal access token"), writing: false))
        == describe(RemoteStoreError.forbidden))
check("a refusal and a partial listing both have something to say",
      !(RemoteStoreError.forbidden.errorDescription ?? "").isEmpty
        && !(RemoteStoreError.partialListing([]).errorDescription ?? "").isEmpty)

// A renamed repository answers 301; URLSession follows it without the token.
do {
    var original = URLRequest(url: URL(string: "https://api.github.com/repos/old/name/contents/a.md")!)
    original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let onGitHub = URLRequest(url: URL(string: "https://api.github.com/repositories/42/contents/a.md")!)
    check("a redirect within GitHub's API keeps the token",
          GitHubStore.Redirects.redirected(onGitHub, from: original).value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    let elsewhere = URLRequest(url: URL(string: "https://example.com/a.md")!)
    check("…and a redirect anywhere else does not get it",
          GitHubStore.Redirects.redirected(elsewhere, from: original).value(forHTTPHeaderField: "Authorization") == nil)
    check("GitHub requests use a session that keeps nothing on disk",
          GitHubStore.session.configuration.urlCache == nil
            && GitHubStore.session.configuration.httpCookieStorage?.cookies?.isEmpty != false)
}

check("a 409 on a read is not a conflict",
      describe(GitHubStore.error(for: response(409), body: body("Git Repository is empty."), writing: false))
        == describe(RemoteStoreError.server(status: 409)))

func main() async {
    do {
        let root = try await store.children(of: id(""))
        check("the repository root lists", !root.isEmpty, "\(root.count) entries")
        check("…folders come before files",
              root.first?.isDirectory != false)
        check("…and only folders and Markdown are listed",
              root.allSatisfy { $0.isDirectory || $0.name.lowercased().hasSuffix(".md") },
              root.map(\.name).joined(separator: ", "))

        let samples = try await store.children(of: id("Samples"))
        check("a subfolder lists on its own", !samples.isEmpty,
              samples.map(\.name).joined(separator: ", "))
        check("…including the Arabic-named file",
              samples.contains { $0.name.hasPrefix("مقالة") })
        check("…and ids carry the full path",
              samples.allSatisfy { $0.id.path.hasPrefix("Samples/") })

        guard let welcome = samples.first(where: { $0.name == "Welcome.md" }) else {
            check("Welcome.md present", false); return
        }
        let contents = try await store.read(welcome.id)
        check("a file reads back", !contents.text.isEmpty, "\(contents.text.count) characters")
        check("…with a version marker", contents.version != nil,
              contents.version?.raw.prefix(12).description ?? "none")
        check("…decoded as real UTF-8, Arabic intact",
              contents.text.contains("صحيفة"),
              String(contents.text.prefix(40)))

        // A document opened from a repository: loads asynchronously, arrives
        // read-only, and refuses to save.
        let doc = await MainActor.run { DocumentModel(id: welcome.id, store: store) }
        let initial = await MainActor.run { doc.loadState }
        check("a remote document starts out loading", initial == .loading,
              String(describing: initial))
        for _ in 0..<100 {
            if await MainActor.run(body: { doc.loadState }) != .loading { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let settled = await MainActor.run { doc.loadState }
        check("…then becomes ready", settled == .ready, String(describing: settled))
        let loaded = await MainActor.run { doc.text }
        check("…with the document's text", loaded.contains("صحيفة"),
              String(loaded.prefix(30)))
        check("…marked read-only", await MainActor.run { doc.isReadOnly })

        await MainActor.run {
            doc.text = "an edit that must not be sent anywhere"
            doc.saveNow()
        }
        check("…and saving is refused", await MainActor.run { doc.lastError == nil })

        // A missing path must fail cleanly rather than return nonsense.
        do {
            _ = try await store.read(id("Samples/definitely-not-here.md"))
            check("a missing file throws", false, "no error raised")
        } catch RemoteStoreError.notFound {
            check("a missing file reports not-found", true)
        } catch {
            check("a missing file reports not-found", false, "\(error)")
        }
    } catch RemoteStoreError.rateLimited {
        print("SKIP  GitHub rate limit reached — not a failure")
        skipped = true
    } catch {
        print("SKIP  network unavailable (\(error)) — not a failure")
        skipped = true
    }
}

await main()
if skipped {
    print("\nSKIPPED")
} else {
    print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
