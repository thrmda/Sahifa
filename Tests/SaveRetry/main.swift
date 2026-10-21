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
    /// How long a write takes, like a request in flight.
    var writeNanos: UInt64 = 0
    private(set) var writeAttempts = 0

    func readImmediately(_ id: DocumentID) -> DocumentContents? {
        DocumentContents(text: text, version: VersionToken(raw: "v"))
    }
    func read(_ id: DocumentID) async throws -> DocumentContents { readImmediately(id)! }
    func versionImmediately(of id: DocumentID) -> VersionToken? { VersionToken(raw: "v") }
    func children(of id: DocumentID) async throws -> [Node] { [] }
    func delete(_ id: DocumentID) async throws {}
    func move(_ id: DocumentID, to destination: DocumentID) async throws {}

    func write(_ text: String, to id: DocumentID, expecting: VersionToken?,
               encoding: TextEncoding) async throws -> VersionToken? {
        writeAttempts += 1
        // Behave like URLSession: a request made from a cancelled task fails
        // with URLError.cancelled. Ignoring cancellation is what hid a retry
        // that cancelled itself every time.
        if Task.isCancelled { throw URLError(.cancelled) }
        if writeNanos > 0 {
            do { try await Task.sleep(nanoseconds: writeNanos) } catch { throw URLError(.cancelled) }
        }
        if failPermanently { throw RemoteStoreError.notAuthorised }
        if failWrites { throw URLError(.notConnectedToInternet) }
        self.text = text
        return VersionToken(raw: "v")
    }
}

/// A slow store that checks versions the way a real one does, so two writes
/// quoting the same version can't both land.
final class VersionedStore: DocumentStore, @unchecked Sendable {
    var isReadOnly = false
    var text = "start"
    private var version = 0
    func readImmediately(_ id: DocumentID) -> DocumentContents? {
        DocumentContents(text: text, version: VersionToken(raw: "\(version)"))
    }
    func read(_ id: DocumentID) async throws -> DocumentContents { readImmediately(id)! }
    func versionImmediately(of id: DocumentID) -> VersionToken? { VersionToken(raw: "\(version)") }
    func children(of id: DocumentID) async throws -> [Node] { [] }
    func delete(_ id: DocumentID) async throws {}
    func move(_ id: DocumentID, to destination: DocumentID) async throws {}
    func write(_ text: String, to id: DocumentID, expecting: VersionToken?,
               encoding: TextEncoding) async throws -> VersionToken? {
        guard expecting?.raw == "\(version)" else { throw DocumentStoreError.versionConflict }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard expecting?.raw == "\(version)" else { throw DocumentStoreError.versionConflict }
        version += 1
        self.text = text
        return VersionToken(raw: "\(version)")
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

    // Typing during a slow save: the autosave that comes due mid-request is
    // skipped, so the save that lands has to pick up what was typed after it.
    let store4 = FlakyStore()
    // Longer than the 1 s autosave debounce, so it comes due mid-request.
    store4.writeNanos = 2_000_000_000
    let doc4 = await MainActor.run { DocumentModel(id: id, store: store4) }
    await MainActor.run {
        doc4.text = "one"
        doc4.saveNow()
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    await MainActor.run {
        doc4.text = "one two"
    }
    // The debounce fires at about 1.2 s, while the first write is still out.
    try? await Task.sleep(nanoseconds: 4_600_000_000)
    check("text typed during a save is saved once it lands",
          store4.text == "one two", store4.text)
    check("…with nothing left unsaved", await MainActor.run { !doc4.hasUnsavedChanges })

    // Quitting (flush) while the follow-up save is in flight must wait for
    // it, not start a write of its own beside it: two writes quoting the same
    // version, and the second reported a conflict with the first.
    let store6 = VersionedStore()
    let doc6 = await MainActor.run { DocumentModel(id: id, store: store6) }
    await MainActor.run {
        doc6.text = "first"
        doc6.saveNow()
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    await MainActor.run {
        doc6.text = "first second"
        doc6.saveNow()   // skipped mid-save, so the landing save starts another
    }
    await doc6.flush()
    check("flush waits for a follow-up save instead of racing it",
          await MainActor.run { !doc6.hasConflict && !doc6.hasUnsavedChanges },
          "conflict \(await MainActor.run { doc6.hasConflict }), stored \(store6.text)")
    check("…and the last text is what's stored", store6.text == "first second", store6.text)

    // Typing back to the old text while a save is out: the baseline has to
    // become what the store now holds, or the document reads clean while the
    // file differs and a quit drops the difference.
    let store7 = FlakyStore()
    store7.writeNanos = 600_000_000
    let doc7 = await MainActor.run { DocumentModel(id: id, store: store7) }
    await MainActor.run {
        doc7.text = "start A"
        doc7.saveNow()
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    await MainActor.run { doc7.text = "start" }
    try? await Task.sleep(nanoseconds: 800_000_000)
    check("the in-flight text landed", store7.text == "start A", store7.text)
    check("reverting to the old text during a save still counts as unsaved",
          await MainActor.run { doc7.hasUnsavedChanges })
    await doc7.flush()
    check("…and flush writes it", store7.text == "start", store7.text)

    // Two paths asking for a save in the same pass (the autosave timer and a
    // retry on reactivation) must not run two writes side by side: the
    // second quoted the first's version and came back as a conflict.
    let store8 = FlakyStore()
    store8.failWrites = true
    let doc8 = await MainActor.run { DocumentModel(id: id, store: store8) }
    await MainActor.run {
        doc8.text = "retry me"
        doc8.saveNow()
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    check("the write failed into retrying", await MainActor.run { doc8.saveStatus == .retrying })
    let before = store8.writeAttempts
    store8.failWrites = false
    store8.writeNanos = 300_000_000
    await MainActor.run {
        doc8.saveNow()
        doc8.retrySave()
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    check("a save and a retry in one pass make one write, not two",
          store8.writeAttempts == before + 1, "\(store8.writeAttempts - before) writes")
    check("…and it lands without a conflict",
          await MainActor.run { !doc8.hasConflict && !doc8.hasUnsavedChanges } && store8.text == "retry me")

    // A credential arriving while a save is held: swapping the store lets the
    // held edit through without waiting for a keystroke.
    let readOnly = FlakyStore()
    readOnly.failPermanently = true
    let doc5 = await MainActor.run { DocumentModel(id: id, store: readOnly) }
    await MainActor.run {
        doc5.text = "held"
        doc5.saveNow()
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let connected = FlakyStore()
    await MainActor.run { doc5.replaceStore(connected) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    check("a replaced store saves the held edit", connected.text == "held", connected.text)
}
await main()
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
