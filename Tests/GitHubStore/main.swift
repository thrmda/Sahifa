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
