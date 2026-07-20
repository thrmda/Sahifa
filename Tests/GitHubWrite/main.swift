import Foundation

// Saving back to a real repository. Opt-in: this writes, so it runs only when
// told which repository to use, and only with a credential already connected.
//
//   SAHIFA_TEST_REPO=owner/name scripts/test-github-write.sh
//
//   SAHIFA_TEST_REPO=owner/name SAHIFA_TEST_TOKEN=… scripts/test-github-write.sh
//
// The token comes from the environment rather than the Keychain on purpose: a
// test binary is newly built each run, so reading the app's stored credential
// makes macOS ask for the keychain password every time.
//
// It works in a uniquely named scratch document and deletes it afterwards, so
// it never touches anything else in the repository.

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

func main() async {
    guard let repo = ProcessInfo.processInfo.environment["SAHIFA_TEST_REPO"],
          repo.contains("/") else {
        print("SKIP  set SAHIFA_TEST_REPO=owner/name to run the write checks")
        return
    }
    // Deliberately NOT read from the Keychain. A test binary is a new,
    // unsigned executable every build, so reading the app's credential makes
    // macOS prompt for the keychain password on every single run.
    guard let token = ProcessInfo.processInfo.environment["SAHIFA_TEST_TOKEN"],
          !token.isEmpty else {
        print("SKIP  set SAHIFA_TEST_TOKEN to run the write checks")
        return
    }
    let parts = repo.split(separator: "/").map(String.init)
    let store = GitHubStore(sourceID: UUID(), owner: parts[0], repository: parts[1],
                            branch: nil, token: token)
    func id(_ path: String) -> DocumentID { DocumentID(sourceID: store.sourceID, path: path) }

    check("a credentialled repository is writable", !store.isReadOnly)

    let name = "sahifa-write-check-\(getpid()).md"
    let scratch = id(name)

    let created = try? await store.write("# Created by Sahifa\n", to: scratch, expecting: nil)
    check("a document can be created", created != nil)

    // Read straight back with no pause. This passes only because requests
    // bypass the URL cache — without that, the read is answered from the
    // local cache with the previous version, which is exactly the bug that
    // made saving look like it did nothing.
    let readBack = try? await store.read(scratch)
    check("…and reads back immediately, not from a cache",
          readBack?.text == "# Created by Sahifa\n", readBack?.text ?? "nil")
    check("…at the version the write reported", readBack?.version == created)

    let edited = try? await store.write("# Edited\n\nSecond line.\n",
                                        to: scratch, expecting: created)
    check("an edit at the current version is accepted", edited != nil && edited != created)
    let afterEdit = try? await store.read(scratch)
    check("…and the edit is what's stored",
          afterEdit?.text.contains("Second line.") == true)

    // Someone else having written in the meantime is the case the conflict
    // banner exists for; quoting a superseded version stands in for it.
    var refused = false
    do { _ = try await store.write("# Must not land\n", to: scratch, expecting: created) }
    catch DocumentStoreError.versionConflict { refused = true }
    catch { check("a stale write raised the wrong error", false, "\(error)") }
    check("a write at a superseded version is refused as a conflict", refused)
    check("…leaving the stored document untouched",
          (try? await store.read(scratch))?.text.contains("Second line.") == true)

    // The same path the editor takes.
    let doc = await MainActor.run { DocumentModel(id: scratch, store: store) }
    for _ in 0..<100 {
        if await MainActor.run(body: { doc.loadState }) != .loading { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    check("the editor's document loads it",
          await MainActor.run { doc.loadState } == .ready)
    check("…and it is editable", await MainActor.run { !doc.isReadOnly })
    await MainActor.run { doc.text = "# Saved through the editor\n" }
    await doc.flush()
    check("…and saving through it reaches the repository",
          (try? await store.read(scratch))?.text == "# Saved through the editor\n")

    // Create, rename and delete through the same store the app uses.
    let orgName = "sahifa-organise-\(getpid()).md"
    let orgID = id(orgName)
    let made = try? await store.write("# Organise check\n", to: orgID, expecting: nil)
    check("a document can be created empty-then-written", made != nil)

    let renamedName = "sahifa-organise-\(getpid())-renamed.md"
    let renamedID = id(renamedName)
    do {
        try await store.move(orgID, to: renamedID)
        check("a document can be moved to a new name", true)
    } catch {
        check("a document can be moved to a new name", false, "\(error)")
    }
    let atNew = try? await store.read(renamedID)
    check("…the content is at the new name", atNew?.text == "# Organise check\n")
    var oldGone = false
    do { _ = try await store.read(orgID) }
    catch RemoteStoreError.notFound { oldGone = true }
    catch {}
    check("…and the old name is gone", oldGone)

    do {
        try await store.delete(renamedID)
        check("a document can be deleted", true)
    } catch {
        check("a document can be deleted", false, "\(error)")
    }
    var deletedGone = false
    do { _ = try await store.read(renamedID) }
    catch RemoteStoreError.notFound { deletedGone = true }
    catch {}
    check("…and it is really gone afterwards", deletedGone)

    // Remove the scratch document.
    if let last = try? await store.read(scratch), let version = last.version {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(repo)/contents/\(name)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject:
            ["message": "Remove Sahifa write check", "sha": version.raw])
        _ = try? await URLSession.shared.data(for: request)
    }
}

await main()
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
