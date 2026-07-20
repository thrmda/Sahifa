// Failed-save handling: a save that can't reach the server holds the edit and
// either retries on its own (offline, timeout, 5xx) or waits for the user (a
// refused token). Driven by a fake flaky store so no real network is needed.
//
import Foundation

var failures = 0
func check(_ l: String, _ c: Bool, _ d: String = "") {
    print("\(c ? "PASS" : "FAIL")  \(l)\(d.isEmpty ? "" : "  — \(d)")")
    if !c { failures += 1 }
}

/// A store whose writes fail on demand, so retry can be tested without taking
/// the network down. Reads are instant, like a local file.
final class FlakyStore: DocumentStore, @unchecked Sendable {
    var isReadOnly = false
    var text = "start"
    var failWrites = false
    var failPermanently = false
    private(set) var writeAttempts = 0

    func readImmediately(_ id: DocumentID) -> DocumentContents? {
        DocumentContents(text: text, version: VersionToken(raw: "v"))
    }
    func read(_ id: DocumentID) async throws -> DocumentContents { readImmediately(id)! }
    func versionImmediately(of id: DocumentID) -> VersionToken? { VersionToken(raw: "v") }
    func children(of id: DocumentID) async throws -> [Node] { [] }
    func delete(_ id: DocumentID) async throws {}
    func move(_ id: DocumentID, to destination: DocumentID) async throws {}

    func write(_ text: String, to id: DocumentID, expecting: VersionToken?) async throws -> VersionToken? {
        writeAttempts += 1
        if failPermanently { throw RemoteStoreError.notAuthorised }
        if failWrites { throw URLError(.notConnectedToInternet) }
        self.text = text
        return VersionToken(raw: "v")
    }
}

func main() async {
    let store = FlakyStore()
    let id = DocumentID(sourceID: UUID(), path: "note.md")
    let doc = await MainActor.run { DocumentModel(id: id, store: store) }

    // A retryable failure: the write fails, edits are held, status is retrying.
    store.failWrites = true
    await MainActor.run { doc.text = "edited while offline" }
    try? await Task.sleep(nanoseconds: 1_400_000_000)
    check("a failed retryable save enters the retrying state",
          await MainActor.run { doc.saveStatus } == .retrying,
          String(describing: await MainActor.run { doc.saveStatus }))
    check("…the edit is held, not lost",
          await MainActor.run { doc.hasUnsavedChanges })
    check("…and nothing reached the store",
          store.text == "start", store.text)

    // The network comes back: an explicit retry now succeeds.
    store.failWrites = false
    await MainActor.run { doc.retrySave() }
    try? await Task.sleep(nanoseconds: 400_000_000)
    check("retrying after the network returns saves",
          store.text == "edited while offline", store.text)
    check("…and the state returns to idle",
          await MainActor.run { doc.saveStatus } == .idle,
          String(describing: await MainActor.run { doc.saveStatus }))
    check("…with nothing left unsaved",
          await MainActor.run { !doc.hasUnsavedChanges })

    // The automatic backoff retry also recovers, with no manual nudge.
    let store2 = FlakyStore()
    let doc2 = await MainActor.run { DocumentModel(id: id, store: store2) }
    store2.failWrites = true
    await MainActor.run { doc2.text = "auto-retry please" }
    try? await Task.sleep(nanoseconds: 1_400_000_000)
    check("auto-retry starts in the retrying state",
          await MainActor.run { doc2.saveStatus } == .retrying)
    store2.failWrites = false
    // First backoff is 2 s; wait it out.
    try? await Task.sleep(nanoseconds: 2_600_000_000)
    check("the scheduled retry saves on its own",
          store2.text == "auto-retry please", store2.text)

    // A permanent failure holds the edit but must NOT enter the auto-retry
    // loop — a refused token won't fix itself by waiting. Driven by an explicit
    // saveNow so the assertion doesn't depend on the autosave debounce, whose
    // timing is unreliable in a CLI with no running main run loop.
    let store3 = FlakyStore()
    let doc3 = await MainActor.run { DocumentModel(id: id, store: store3) }
    store3.failPermanently = true
    await MainActor.run {
        doc3.text = "no access"
        doc3.saveNow()
    }
    try? await Task.sleep(nanoseconds: 400_000_000)
    check("a non-retryable failure goes to failed, not retrying",
          await MainActor.run { doc3.saveStatus } == .failed,
          String(describing: await MainActor.run { doc3.saveStatus }))
    check("…and still holds the edit",
          await MainActor.run { doc3.hasUnsavedChanges })
    // The defining property: a .failed state does not recover on its own, so it
    // never flips itself to retrying/saving/idle without the user or a reactivate.
    try? await Task.sleep(nanoseconds: 2_600_000_000)
    check("…and stays failed rather than auto-retrying",
          await MainActor.run { doc3.saveStatus } == .failed,
          String(describing: await MainActor.run { doc3.saveStatus }))

    // resumeSaving (app reactivated) is what recovers a failed save once the
    // cause is gone.
    store3.failPermanently = false
    await MainActor.run { doc3.resumeSaving() }
    try? await Task.sleep(nanoseconds: 400_000_000)
    check("resumeSaving recovers a failed save", store3.text == "no access", store3.text)
    check("…back to idle", await MainActor.run { doc3.saveStatus } == .idle,
          String(describing: await MainActor.run { doc3.saveStatus }))
}
await main()
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
