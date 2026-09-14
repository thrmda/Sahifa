import Combine
import Foundation

/// One open document. Plain text on the other side of a store — no library,
/// no database. Autosaves one second after the last edit.
///
/// The document itself does no file I/O: it holds a `DocumentID`, a store to
/// reach it through, and the version it last read or wrote. That last piece
/// is what makes overwrite detection work, and it is deliberately opaque —
/// modification date and size for a local file today, a revision id for
/// anything fetched later, compared the same way either way.
@MainActor
final class DocumentModel: ObservableObject, Identifiable {
    let id: DocumentID
    @Published var text: String
    @Published private(set) var lastError: String?

    /// Set when the document changed underneath us *and* there are unsaved
    /// edits — the one case where neither version can be chosen automatically.
    /// Autosave stays paused until `resolveKeepingMine`/`resolveUsingDisk`.
    @Published private(set) var hasConflict = false

    /// Loading is a real state now that a document can come over a network.
    /// A local file skips it entirely — its contents are available at once,
    /// and routing them through an await would flash an empty editor on every
    /// document switch.
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }
    @Published private(set) var loadState: LoadState

    /// The file's bytes aren't text Sahifa can write back faithfully — a
    /// legacy encoding, or a file it wasn't allowed to read. What's shown is a
    /// lossy rendering, so saving it would destroy the original.
    @Published private(set) var isUndecodable = false

    /// An undecodable file the user asked to see as Windows-1256. The text is
    /// readable now, but the file stays read-only: saving it back as
    /// Windows-1256 isn't supported, and converting it is a separate, explicit
    /// step (`convertToUTF8`).
    @Published private(set) var isShownAsWindows1256 = false

    /// The bytes behind an undecodable document, for reopening it.
    private var undecodedData: Data?

    var canReopenAsWindows1256: Bool {
        isUndecodable && !isShownAsWindows1256 && undecodedData != nil
    }

    var canConvertToUTF8: Bool { isShownAsWindows1256 && !store.isReadOnly }

    /// Browsable but not savable — a repository with no credential, or a file
    /// that couldn't be decoded.
    var isReadOnly: Bool { store.isReadOnly || isUndecodable }

    /// Where a save is in its life. Distinct from a conflict, which needs a
    /// decision — these states resolve on their own or with one retry.
    ///   idle     nothing outstanding
    ///   saving   a write is in flight
    ///   retrying the last write failed for a reason likely to pass (offline,
    ///            timeout, server hiccup); edits are held and it tries again
    ///   failed   the last write failed for a reason a retry won't fix on its
    ///            own (the token lost access); the edits are still held
    enum SaveStatus: Equatable {
        case idle
        case saving
        case retrying
        case failed
    }
    @Published private(set) var saveStatus: SaveStatus = .idle

    /// A write is in flight. Instant for a local file; long enough to matter
    /// for anything sent over a network, and the reason quitting waits.
    var isSaving: Bool { saveStatus == .saving }

    private var saveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private static let initialRetryNanos: UInt64 = 2_000_000_000    // 2 s
    private static let maxRetryNanos: UInt64 = 30_000_000_000       // 30 s
    private var retryDelayNanos: UInt64 = DocumentModel.initialRetryNanos
    var hasUnsavedChanges: Bool { text != savedText }

    private let store: any DocumentStore
    private var savedText: String
    private var version: VersionToken?
    /// What the document was read in, and so what it's written back in.
    private var encoding: TextEncoding = .utf8
    private var cancellable: AnyCancellable?

    var displayName: String { id.name }

    /// Markdown, or a table. Follows the name: renaming a file to `.csv`
    /// gives it a new ID, and so a new document of the new kind.
    var kind: DocumentKind { id.kind ?? .markdown }

    /// Suggested filename (sans extension) for exports.
    var exportName: String { (id.name as NSString).deletingPathExtension }

    init(id: DocumentID, store: any DocumentStore) {
        self.id = id
        self.store = store
        if let immediate = store.readImmediately(id) {
            self.text = immediate.text
            self.savedText = immediate.text
            self.version = immediate.version
            self.encoding = immediate.encoding ?? .utf8
            self.isUndecodable = immediate.encoding == nil
            self.undecodedData = immediate.undecodedData
            self.loadState = .ready
        } else {
            self.text = ""
            self.savedText = ""
            self.version = nil
            self.loadState = .loading
            Task { [weak self] in await self?.load() }
        }

        cancellable = $text
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveNow()
            }
    }

    /// Fetches a document that wasn't available at once. Failure is reported
    /// rather than swallowed: an empty editor that silently isn't your file is
    /// the worst outcome here.
    private func load() async {
        do {
            let contents = try await store.read(id)
            text = contents.text
            savedText = contents.text
            version = contents.version
            encoding = contents.encoding ?? .utf8
            isUndecodable = contents.encoding == nil
            undecodedData = contents.undecodedData
            isShownAsWindows1256 = false
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func retryLoad() {
        guard case .failed = loadState else { return }
        loadState = .loading
        Task { [weak self] in await self?.load() }
    }

    /// Starts a save without waiting for it — the call sites are UI events.
    /// Use `flush()` when the result actually has to be waited on.
    func saveNow() {
        guard loadState == .ready, !isReadOnly, text != savedText, !hasConflict else { return }
        // Never cancel a save already in flight; let it finish and re-check.
        // Cancelling mid-request is how half-written documents happen.
        guard !isSaving else { return }
        saveTask = Task { [weak self] in await self?.write() }
    }

    /// Awaits any save in flight, then saves anything still outstanding.
    /// Quitting and switching documents both go through this.
    func flush() async {
        await saveTask?.value
        guard loadState == .ready, !isReadOnly, text != savedText, !hasConflict else { return }
        await write()
    }

    /// Try a failed save again now, rather than waiting out the backoff — the
    /// Retry button, and what a returning network is worth a shot at.
    func retrySave() {
        guard saveStatus == .retrying || saveStatus == .failed else { return }
        retryDelayNanos = Self.initialRetryNanos
        retryTask?.cancel()
        saveTask = Task { [weak self] in await self?.write() }
    }

    /// Called when the app regains focus — the network is most likely back, so
    /// a stalled save is worth another immediate attempt.
    func resumeSaving() {
        if saveStatus == .retrying || saveStatus == .failed { retrySave() }
    }

    /// Picks up edits made by other programs. A document with nothing unsaved
    /// simply follows the file; one with unsaved edits raises a conflict
    /// rather than picking a winner on the user's behalf.
    func reconcileWithDisk() {
        guard loadState == .ready,
              let current = store.versionImmediately(of: id), current != version else { return }
        guard text == savedText else {
            hasConflict = true
            return
        }
        reload()
    }

    // MARK: Legacy encodings

    /// Shows an undecodable file as Windows-1256. Nothing is written.
    func reopenAsWindows1256() {
        guard canReopenAsWindows1256, let data = undecodedData,
              let decoded = TextEncoding.decodeWindows1256(data) else { return }
        text = decoded
        savedText = decoded
        isShownAsWindows1256 = true
    }

    /// Rewrites a file shown as Windows-1256 as UTF-8, after which it edits
    /// like any other. A table gets a byte-order mark, which Excel needs to
    /// read the Arabic; Markdown doesn't. Only ever on an explicit request.
    func convertToUTF8() {
        guard canConvertToUTF8 else { return }
        encoding = kind.isTable ? .utf8WithBOM : .utf8
        isUndecodable = false
        isShownAsWindows1256 = false
        undecodedData = nil
        saveTask = Task { [weak self] in await self?.write() }
    }

    /// Awaits a conversion or any other save in flight.
    func waitForSave() async {
        await saveTask?.value
    }

    // MARK: Conflict resolution

    /// Keep what's in the editor, overwriting whatever is stored.
    func resolveKeepingMine() {
        Task { [weak self] in
            guard let self else { return }
            // Adopt whatever is stored now as the base, so the write is
            // accepted. A remote store can only answer that by fetching.
            if let immediate = store.versionImmediately(of: id) {
                version = immediate
            } else if let fetched = try? await store.read(id) {
                version = fetched.version
            }
            hasConflict = false
            await write()
        }
    }

    /// Take the stored version, discarding unsaved edits in the editor.
    func resolveUsingDisk() {
        reload()
    }

    // MARK: Reading and writing

    private func write() async {
        // A fresh attempt supersedes any scheduled retry.
        retryTask?.cancel()
        saveStatus = .saving
        let attempted = text
        do {
            version = try await store.write(attempted, to: id, expecting: version,
                                            encoding: encoding)
            // Compare against what was actually sent: more may have been typed
            // while the request was in flight, and that is still unsaved.
            if text == attempted { savedText = attempted }
            hasConflict = false
            lastError = nil
            saveStatus = .idle
            retryDelayNanos = Self.initialRetryNanos
        } catch DocumentStoreError.versionConflict {
            // A conflict is a decision, not a retry — the banner takes over and
            // autosave stays paused until it's resolved.
            hasConflict = true
            saveStatus = .idle
        } catch {
            // The edits stay unsaved (savedText is untouched), so nothing is
            // lost. Retryable failures schedule another attempt; the rest wait
            // for the user, but still hold the text.
            lastError = error.localizedDescription
            if Self.isRetryable(error) {
                saveStatus = .retrying
                scheduleRetry()
            } else {
                saveStatus = .failed
            }
        }
    }

    /// Failures worth retrying on their own: the network being down or slow,
    /// and the server being briefly unwell. A refused credential or a missing
    /// path won't fix itself by waiting, so those surface and hold instead.
    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }
        switch error {
        case RemoteStoreError.rateLimited:
            return true
        case RemoteStoreError.server(let status) where status == 0 || status >= 500:
            return true
        default:
            return false
        }
    }

    private func scheduleRetry() {
        let delay = retryDelayNanos
        retryDelayNanos = min(retryDelayNanos * 2, Self.maxRetryNanos)   // back off
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            guard self.saveStatus == .retrying, self.hasUnsavedChanges, !self.hasConflict
            else { return }
            await self.write()
        }
    }

    private func reload() {
        guard let contents = store.readImmediately(id) else {
            loadState = .loading
            Task { [weak self] in await self?.load() }
            return
        }
        // Assigning `text` re-triggers the autosave debounce, but by then it
        // equals `savedText`, so the save is a no-op.
        text = contents.text
        savedText = contents.text
        version = contents.version
        // Another program may have converted the file, in either direction.
        encoding = contents.encoding ?? .utf8
        isUndecodable = contents.encoding == nil
        undecodedData = contents.undecodedData
        isShownAsWindows1256 = false
        hasConflict = false
        lastError = nil
    }
}
