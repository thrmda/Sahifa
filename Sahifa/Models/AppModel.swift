import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// App-wide state: the list of sources the user has added and the documents
/// opened from them.
///
/// Sources are a list, not a single workspace. Opening a folder *adds* a
/// root; opening a file selects it where it already lives, or files it under
/// the built-in loose-files source. Nothing is silently replaced, which is
/// what the old single-workspace model did every time a file was opened from
/// Finder.
@MainActor
final class AppModel: ObservableObject {
    /// Single instance: the SwiftUI scene owns it as a StateObject, and the
    /// app delegate reaches it for Finder open events (application(_:open:)).
    static let shared = AppModel()

    @Published private(set) var sources: [Source] = []
    @Published private(set) var recentItems: [RecentItem] = []

    /// Children per directory, filled in as the user expands the tree. `nil`
    /// means "not read yet" — the sidebar shows a chevron and loads on
    /// demand, because eagerly walking a real notes folder is wasteful and
    /// no remote source could do it at all.
    @Published private(set) var childrenByDirectory: [DocumentID: [Node]] = [:]

    /// Documents opened on their own, listed under the loose-files source.
    @Published private(set) var looseFiles: [URL] = []

    /// Folders currently being fetched, and folders that failed. Local folders
    /// are read instantly and never appear here; a repository has to be waited
    /// on, and can refuse.
    @Published private(set) var loadingDirectories: Set<DocumentID> = []
    @Published private(set) var directoryErrors: [DocumentID: String] = [:]

    /// One DocumentModel per document, shared by every window showing it.
    private var documentCache: [DocumentID: DocumentModel] = [:]

    /// One recursive watcher per local source root.
    private var monitors: [UUID: DirectoryWatcher] = [:]

    /// Follows the GitHub account once a repository is in use (see
    /// `observeAccountIfNeeded`).
    private var accountObservation: AnyCancellable?

    /// Which window's state receives externally opened documents (last key
    /// window; see KeyWindowTracker in ContentView).
    weak var frontWindowState: WindowState?
    /// External open that arrived before any window attached (cold launch via
    /// Finder); consumed by the first WindowState.attach.
    private var pendingSelection: DocumentID?
    /// Opens a fresh window. Supplied by the window layer because SwiftUI's
    /// `openWindow` lives in the view environment, and needed here for the one
    /// case with no window to hand a file to: the app running, every window
    /// closed. Set on the first window's appear, so it is in place well before
    /// the app can reach that state.
    var requestNewWindow: (() -> Void)?

    /// Fires when a source is added, so a window with nothing open adopts it.
    /// Windows already showing a document are left alone.
    let sourceAdded = PassthroughSubject<Source, Never>()

    init() {
        recentItems = loadRecents()
        restoreSources()
        // Dev convenience: `Sahifa -workspace /path` adds a folder or opens a
        // single Markdown file directly (useful for testing; under the
        // sandbox, arbitrary paths only resolve when access is otherwise
        // granted).
        if let index = CommandLine.arguments.firstIndex(of: "-workspace"),
           index + 1 < CommandLine.arguments.count {
            openExternal([URL(fileURLWithPath: CommandLine.arguments[index + 1])])
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAll() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAll() }
        }
        // Coming back to the app is when another program is most likely to
        // have edited a file we have open — reconcile before the user resumes
        // typing into a stale document, and re-read the tree they can see.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for document in self.documentCache.values {
                    document.reconcileWithDisk()
                    // The network is most likely back — nudge any stalled save.
                    document.resumeSaving()
                }
                self.refreshLoadedDirectories()
            }
        }
    }

    // MARK: Sources

    func source(_ id: UUID) -> Source? {
        sources.first { $0.id == id }
    }

    func url(for id: DocumentID) -> URL? {
        source(id.sourceID)?.url(for: id)
    }

    /// Folder and file opening are separate panels on purpose: a combined
    /// panel (canChooseFiles + canChooseDirectories + content-type filter)
    /// makes the Open button descend into a highlighted folder instead of
    /// choosing it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        openExternal(panel.urls)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.openableTypes
        guard panel.runModal() == .OK else { return }
        openExternal(panel.urls)
    }

    /// Derived from `DocumentKind.openableExtensions` rather than listed
    /// again, so the Open panel can never fall behind the extensions the tree
    /// recognises — which is exactly how .mdx came to be browsable but greyed
    /// out in ⌘O.
    private static let openableTypes: [UTType] =
        DocumentKind.openableExtensions.compactMap { UTType(filenameExtension: $0) }

    static func isOpenable(_ url: URL) -> Bool {
        DocumentKind(fileName: url.lastPathComponent) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }

    /// Entry point for anything arriving from outside the app's own panels:
    /// Finder "Open With", double-click, Dock-icon drops, drag-drop, and the
    /// Open panels above. Folders become sources; files are selected where
    /// they already live, or filed under loose files.
    func openExternal(_ urls: [URL], preferring target: WindowState? = nil) {
        var opened: [DocumentID] = []
        for url in urls {
            if Self.isDirectory(url) {
                addFolderSource(url)
            } else if Self.isOpenable(url), let id = adoptFile(url) {
                opened.append(id)
            }
        }
        guard !opened.isEmpty else { return }
        // Anything arriving from outside — Open File…, Finder, a drop — opens as
        // a new tab (sidebar clicks are the "reuse the current tab" path). When
        // no window exists yet (cold launch), the last one seeds it.
        if let windowState = target ?? frontWindowState {
            for id in opened { windowState.openInNewTab(id) }
        } else {
            // No window to put a tab in — either a cold launch from Finder, or
            // the app running with every window closed. Stage the file and ask
            // for a window to receive it; the first attach consumes the staged
            // selection (the same route a detached tab takes). On cold launch
            // the window is already on its way, and openWindow is a no-op then.
            pendingSelection = opened.last
            if let requestNewWindow { requestNewWindow() } else { Self.openWindowViaNewWindowCommand() }
        }
    }

    /// Opens a window when SwiftUI's `openWindow` isn't reachable yet: a Finder
    /// launch delivers the file before any window — and so before any view
    /// environment — exists, and with the group not handling external events
    /// SwiftUI won't make one on its own. The File ▸ New Window command does
    /// exactly the right thing and is built at launch, so drive that. Matched
    /// by its ⇧⌘N shortcut, not its title, which is localized.
    private static func openWindowViaNewWindowCommand() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items
            where item.keyEquivalent == "n"
                && item.keyEquivalentModifierMask == [.command, .shift] {
                submenu.performActionForItem(at: submenu.index(of: item))
                return
            }
        }
    }

    @discardableResult
    private func addFolderSource(_ url: URL) -> Source? {
        saveBookmark(url)
        // Already added: refresh it rather than listing the same folder twice.
        if let existing = sources.first(where: {
            $0.kind == .localFolder && $0.rootURL?.standardizedFileURL == url.standardizedFileURL
        }) {
            loadChildren(of: DocumentID(sourceID: existing.id, path: ""), force: true)
            return existing
        }
        let source = Source(id: UUID(), kind: .localFolder,
                            name: url.lastPathComponent, rootURL: url)
        sources.append(source)
        persistSources()
        loadChildren(of: DocumentID(sourceID: source.id, path: ""), force: true)
        startMonitor(for: source)
        sourceAdded.send(source)
        return source
    }

    /// A file opens where it already lives if one of the added folders
    /// contains it; only genuinely homeless files land in loose files.
    private func adoptFile(_ url: URL) -> DocumentID? {
        saveBookmark(url)
        if let owner = sources.first(where: {
            $0.kind == .localFolder && $0.documentID(for: url) != nil
        }), let id = owner.documentID(for: url) {
            revealAncestors(of: id)
            return id
        }
        if !looseFiles.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            looseFiles.append(url)
            persistLooseFiles()
        }
        ensureLooseFilesSource()
        refreshLooseFiles()
        return looseSource().documentID(for: url)
    }

    /// Makes sure every directory above a document has been read, so the
    /// sidebar can show and select it without the user expanding by hand.
    private func revealAncestors(of id: DocumentID) {
        var components = id.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }
        components.removeLast()
        var current = DocumentID(sourceID: id.sourceID, path: "")
        loadChildren(of: current)
        for component in components {
            current = current.appending(component)
            loadChildren(of: current)
        }
    }

    /// Reorders the source roots (drag-to-reorder in the sidebar) and persists
    /// the new order so it survives relaunch.
    func moveSources(fromOffsets: IndexSet, toOffset: Int) {
        sources.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistSources()
    }

    /// One-step reorder that works regardless of which roots are collapsed —
    /// the reliable path that the sidebar's Move Up / Move Down use, since the
    /// native drag can't always drop past a collapsed root.
    func moveSourceUp(_ id: UUID) {
        guard let i = sources.firstIndex(where: { $0.id == id }), i > 0 else { return }
        sources.swapAt(i, i - 1)
        persistSources()
    }

    func moveSourceDown(_ id: UUID) {
        guard let i = sources.firstIndex(where: { $0.id == id }), i < sources.count - 1 else { return }
        sources.swapAt(i, i + 1)
        persistSources()
    }

    func removeSource(_ id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let source = sources[index]
        monitors[id]?.stop()
        monitors[id] = nil
        sourceBookmarks[id] = nil
        sources.remove(at: index)
        childrenByDirectory = childrenByDirectory.filter { $0.key.sourceID != id }
        // Its open documents go too: left cached, they kept autosaving (with
        // the old token, for a repository) and a second model turned up for
        // the same file when the folder was added again. Each lands its
        // unsaved text first; the task holds it alive until then.
        let root = DocumentID(sourceID: id, path: "")
        for key in documentCache.keys where key.sourceID == id {
            if let document = documentCache.removeValue(forKey: key) {
                Task { await document.flush() }
            }
        }
        documentMoved.send((from: root, to: nil))
        if source.kind == .looseFiles {
            looseFiles = []
            unavailableLooseBookmarks = []
            persistLooseFiles()
        }
        persistSources()
    }

    private func looseSource() -> Source {
        sources.first { $0.kind == .looseFiles } ?? Source.looseFiles()
    }

    private func ensureLooseFilesSource() {
        guard !sources.contains(where: { $0.kind == .looseFiles }) else { return }
        sources.append(Source.looseFiles())
    }

    // MARK: Tree

    /// Children of a directory, or nil when it hasn't been read yet.
    func children(of id: DocumentID) -> [Node]? {
        childrenByDirectory[id]
    }

    /// Reads one directory's children. Cheap and shallow by design: the tree
    /// fills in as the user opens it.
    func loadChildren(of id: DocumentID, force: Bool = false) {
        guard force || childrenByDirectory[id] == nil else { return }
        guard let source = source(id.sourceID) else { return }
        if source.kind == .looseFiles {
            childrenByDirectory[id] = looseFileNodes()
            return
        }
        if source.kind == .gitHub {
            fetchChildren(of: id)
            return
        }
        guard let store = store(for: id.sourceID) as? LocalFileStore else { return }
        if let nodes = store.childrenIfReadable(of: id) {
            childrenByDirectory[id] = nodes
        } else if childrenByDirectory[id] == nil {
            childrenByDirectory[id] = []
        }
        // Otherwise the folder couldn't be read just now: keep what was
        // listed rather than showing it empty and closing its tabs.
    }

    /// Fetches a remote folder. Only one request per folder is in flight, and
    /// the result replaces any previous error for that folder.
    private func fetchChildren(of id: DocumentID) {
        guard !loadingDirectories.contains(id), let store = store(for: id.sourceID) else { return }
        loadingDirectories.insert(id)
        directoryErrors[id] = nil
        Task { [weak self] in
            do {
                let nodes = try await store.children(of: id)
                guard let self else { return }
                self.childrenByDirectory[id] = nodes
                self.loadingDirectories.remove(id)
            } catch {
                guard let self else { return }
                // A refused credential is an account problem, not a folder
                // problem — say so on the account so every source reflects it.
                // A 403 is this repository refusing (an organisation's rules,
                // a token scoped elsewhere), which says nothing about the
                // token's other repositories.
                if case RemoteStoreError.notAuthorised = error {
                    GitHubAccount.shared.markRefused()
                    self.markNeedsSignIn(sourceID: id.sourceID)
                }
                // GitHub lists at most 1,000 entries: show those, and say so.
                if case RemoteStoreError.partialListing(let nodes) = error {
                    self.childrenByDirectory[id] = nodes
                }
                self.directoryErrors[id] = error.localizedDescription
                self.loadingDirectories.remove(id)
            }
        }
    }

    /// A store holds the token it was made with, so an open repository
    /// document would otherwise keep the credential it was opened under:
    /// read-only after connecting, still writing after disconnecting. Started
    /// only once a repository store exists, so a launch with no repository
    /// never reaches the Keychain.
    private func observeAccountIfNeeded() {
        guard accountObservation == nil else { return }
        accountObservation = GitHubAccount.shared.$state
            .dropFirst()
            .removeDuplicates()
            // @Published announces before the value changes; the stores have
            // to be rebuilt from the new one.
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.accountChanged(state) }
            }
    }

    private func accountChanged(_ state: GitHubAccount.State) {
        // Whether files can be created in a repository follows the credential,
        // and nothing below changes a published value for a public repository
        // that was browsed fine without one: New File stayed greyed out after
        // connecting, and enabled after disconnecting.
        objectWillChange.send()
        let remote = Set(sources.filter { $0.kind == .gitHub }.map(\.id))
        for (id, document) in documentCache where remote.contains(id.sourceID) {
            if let store = store(for: id.sourceID) { document.replaceStore(store) }
        }
        guard case .connected = state else { return }
        // Signed in again: clear the badges, and fetch what was refused.
        for index in sources.indices where sources[index].status == .needsSignIn {
            sources[index].status = .ready
        }
        for id in directoryErrors.keys where remote.contains(id.sourceID) {
            loadChildren(of: id, force: true)
        }
    }

    private func markNeedsSignIn(sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].status = .needsSignIn
    }

    /// Adds a GitHub repository as a source. Read-only for now, and read
    /// anonymously, which is enough for public repositories.
    func addRepository(owner: String, name: String, branch: String?) {
        let trimmedOwner = owner.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Both end up in request paths; refuse anything GitHub couldn't have.
        guard GitHubStore.isValidOwner(trimmedOwner),
              GitHubStore.isValidRepositoryName(trimmedName) else { return }
        // GitHub names are case-insensitive: Apple/Swift-Markdown is the same
        // repository as apple/swift-markdown.
        if let existing = sources.first(where: {
            $0.repository?.owner.caseInsensitiveCompare(trimmedOwner) == .orderedSame
                && $0.repository?.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) {
            loadChildren(of: DocumentID(sourceID: existing.id, path: ""), force: true)
            return
        }
        let source = Source(id: UUID(), kind: .gitHub,
                            name: "\(trimmedOwner)/\(trimmedName)",
                            rootURL: nil,
                            repository: Source.Repository(owner: trimmedOwner,
                                                          name: trimmedName,
                                                          branch: branch))
        sources.append(source)
        persistSources()
        loadChildren(of: DocumentID(sourceID: source.id, path: ""), force: true)
        sourceAdded.send(source)
    }

    private func looseFileNodes() -> [Node] {
        let source = looseSource()
        return looseFiles.compactMap { url in
            guard let id = source.documentID(for: url) else { return nil }
            return Node(id: id, name: url.lastPathComponent, isDirectory: false)
        }
    }

    private func refreshLooseFiles() {
        let gone = looseFiles.filter { !FileManager.default.fileExists(atPath: $0.path) }
        for url in gone {
            let bookmark = looseBookmarks.removeValue(forKey: url.standardizedFileURL)
            if let bookmark, Self.isOnUnmountedVolume(url) {
                unavailableLooseBookmarks.append(bookmark)
            }
        }
        looseFiles.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        // Files whose drive has come back are listed again.
        unavailableLooseBookmarks.removeAll { bookmark in
            if let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path,
               Self.isOnUnmountedVolume(URL(fileURLWithPath: path)) {
                return false
            }
            if let url = resolveBookmark(bookmark), FileManager.default.fileExists(atPath: url.path),
               !looseFiles.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                looseFiles.append(url)
                looseBookmarks[url.standardizedFileURL] = bookmark
            }
            return true
        }
        if !looseFiles.isEmpty { ensureLooseFilesSource() }
        let root = DocumentID(sourceID: Source.looseFilesID, path: "")
        if childrenByDirectory[root] != nil || !looseFiles.isEmpty {
            childrenByDirectory[root] = looseFileNodes()
        }
        if looseFiles.isEmpty {
            sources.removeAll { $0.kind == .looseFiles }
        }
        persistLooseFiles()
    }

    /// Re-reads every directory already on screen, and re-checks that each
    /// source still exists.
    func refreshLoadedDirectories() {
        for index in sources.indices where sources[index].kind == .localFolder {
            let path = sources[index].rootURL?.path
            let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            sources[index].status = exists ? .ready : .missing
        }
        // Local folders only: re-reading every remote folder on each app
        // switch would burn requests for no reason.
        for id in childrenByDirectory.keys
        where source(id.sourceID)?.kind == .localFolder && source(id.sourceID)?.status == .ready {
            loadChildren(of: id, force: true)
        }
        refreshLooseFiles()
    }

    // MARK: Documents

    func document(for id: DocumentID) -> DocumentModel? {
        if let existing = documentCache[id] {
            // Cached from an earlier visit: another program may have changed
            // the file since, while the app stayed in front and no activation
            // came along to notice.
            existing.reconcileWithDisk()
            return existing
        }
        guard let store = store(for: id.sourceID) else { return nil }
        let document = DocumentModel(id: id, store: store)
        documentCache[id] = document
        return document
    }

    /// How documents in a source are reached. Everything above this line is
    /// source-agnostic; this is the one place that knows the difference.
    func store(for sourceID: UUID) -> (any DocumentStore)? {
        guard let source = source(sourceID) else { return nil }
        switch source.kind {
        case .localFolder, .looseFiles:
            guard let root = source.rootURL else { return nil }
            return LocalFileStore(sourceID: sourceID, root: root)
        case .gitHub:
            guard let repository = source.repository else { return nil }
            observeAccountIfNeeded()
            return GitHubStore(sourceID: sourceID,
                               owner: repository.owner,
                               repository: repository.name,
                               branch: repository.branch,
                               token: GitHubAccount.shared.token)
        }
    }

    /// Whether a document still resolves to something on disk — the sidebar
    /// drops selections that don't.
    func exists(_ id: DocumentID) -> Bool {
        guard let url = url(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The first document a new window should show.
    var defaultSelection: DocumentID? {
        for source in sources {
            let root = DocumentID(sourceID: source.id, path: "")
            loadChildren(of: root)
            if let first = children(of: root)?.first(where: { !$0.isDirectory }) {
                return first.id
            }
        }
        return nil
    }

    /// One-shot: an external open that arrived before any window existed.
    func takePendingSelection() -> DocumentID? {
        defer { pendingSelection = nil }
        return pendingSelection
    }

    /// Stages a document so the next window to open shows it — used when a tab
    /// is dragged out of the bar to become its own window.
    func stagePendingSelection(_ id: DocumentID) {
        pendingSelection = id
    }

    /// Creates an empty Untitled document in `directory` — a folder in any
    /// writable source, local or remote. The free name is chosen from the
    /// listing the sidebar already has rather than by asking the store, which
    /// would be a request per attempt against a repository.
    @discardableResult
    func newFile(in directory: DocumentID?) async throws -> DocumentID? {
        // Loose files have no folder of their own to create into: the "root"
        // there is the whole disk.
        let requested = directory.flatMap { canCreate(in: $0) ? $0 : nil }
        guard let target = requested ?? firstWritableDirectory(),
              let store = store(for: target.sourceID), !store.isReadOnly
        else { return nil }
        loadChildren(of: target)
        let taken = Set((children(of: target) ?? []).map(\.name))
        let base = String(localized: "Untitled")
        var name = "\(base).md"
        var counter = 2
        while taken.contains(name) {
            name = "\(base) \(counter).md"
            counter += 1
        }
        let id = target.appending(name)
        _ = try await store.write("", to: id, expecting: nil)
        loadChildren(of: target, force: true)
        return id
    }

    /// Whether a new file can be made in `directory` itself.
    func canCreate(in directory: DocumentID) -> Bool {
        guard let source = source(directory.sourceID), source.kind != .looseFiles else { return false }
        return store(for: directory.sourceID)?.isReadOnly == false
    }

    private func firstWritableDirectory() -> DocumentID? {
        sources.first { source in
            source.kind != .looseFiles && store(for: source.id)?.isReadOnly == false
        }
        .map { DocumentID(sourceID: $0.id, path: "") }
    }

    var canCreateFiles: Bool { firstWritableDirectory() != nil }

    /// Whether a document can be renamed or removed. Loose files are excluded:
    /// they are listed by the app, not owned by a folder it manages.
    ///
    /// A repository's folders are excluded too: its contents API renames and
    /// deletes one file per commit, and has no call for a folder at all.
    func canOrganise(_ id: DocumentID, isDirectory: Bool = false) -> Bool {
        guard let source = source(id.sourceID), source.kind != .looseFiles else { return false }
        if isDirectory && !source.isLocal { return false }
        return store(for: id.sourceID)?.isReadOnly == false
    }

    func saveAll() {
        for document in documentCache.values {
            document.saveNow()
        }
    }

    /// Anything still to be written — asked before letting the app quit.
    var hasPendingSaves: Bool {
        documentCache.values.contains { $0.isSaving || $0.hasUnsavedChanges }
    }

    /// Documents with edits that still aren't saved after `flushAll`: a
    /// remote save that couldn't reach the server, a conflict waiting on a
    /// decision, or a local write the disk refused. What a quit-time warning
    /// is about.
    var documentsWithUnsavedChanges: [DocumentModel] {
        documentCache.values.filter { $0.hasUnsavedChanges }
    }

    /// Awaits every outstanding save. A local file finishes immediately; a
    /// remote one is a request that quitting has to wait for, or the last
    /// thing typed is lost.
    func flushAll() async {
        for document in documentCache.values {
            await document.flush()
        }
    }

    // MARK: Renaming and deleting

    /// Announces that a document (or a whole folder) moved or went away, so
    /// each window can fix up its own selection and expanded folders. `to` is
    /// nil when the item was deleted.
    let documentMoved = PassthroughSubject<(from: DocumentID, to: DocumentID?), Never>()

    /// Renames a file or folder. The new name is the *whole* filename, as in
    /// Finder — but dropping the extension would quietly take a file out of
    /// the tree, so an omitted extension keeps the old one.
    /// Async because pending edits must reach disk *before* the file moves —
    /// saving is no longer instant, and a write landing after the move would
    /// recreate the file under its old name.
    ///
    /// Returns nil when there is nothing to do (the name didn't change), and
    /// throws when the rename can't happen, so the caller can say why.
    @discardableResult
    func rename(_ id: DocumentID, to proposed: String) async throws -> DocumentID? {
        guard canOrganise(id), let store = store(for: id.sourceID), let parent = id.parent
        else { throw OrganiseError.notAllowed }
        let isDirectory = children(of: parent)?.first(where: { $0.id == id })?.isDirectory
            ?? (children(of: id) != nil)
        let name = try Self.renamedName(proposed, from: id.name, isDirectory: isDirectory)
        guard name != id.name else { return nil }
        // Case-only renames are allowed; anything else matching an existing
        // name is refused. Local volumes are usually case-insensitive, so
        // "Notes.md" next to "notes.md" is the same file to them.
        let siblings = (children(of: parent) ?? []).map(\.name).filter { $0 != id.name }
        if siblings.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw OrganiseError.nameTaken(name)
        }

        // Every open document at or under `id` moves with it. A conflict needs
        // the user's decision first; moving would silently drop their side.
        let affected = documentCache.filter { $0.key.isWithin(id) }
        if affected.values.contains(where: \.hasConflict) {
            throw OrganiseError.unresolvedConflict
        }
        // Pending edits reach the old file before it moves, and then nothing
        // more is written there: a save landing after the move would recreate
        // the file under its old name.
        for document in affected.values { await document.flush() }
        for document in affected.values {
            document.detach()
            await document.waitForSave()
        }
        let newID = parent.appending(name)
        do {
            try await store.move(id, to: newID)
        } catch {
            for document in affected.values { document.reattach() }
            throw error
        }
        relocate(from: id, to: newID)
        // Anything typed while the move was under way (or a save that failed
        // and was still being held) carries over to the document at its new
        // name rather than being lost with the old model.
        for (key, old) in affected where old.hasUnsavedChanges {
            guard let newKey = key.remapping(from: id, to: newID) else { continue }
            document(for: newKey)?.adoptUnsavedText(old.text)
        }
        loadChildren(of: parent, force: true)
        return newID
    }

    /// The whole filename a rename produces. A file keeps its extension when
    /// the new name doesn't end in one Sahifa opens, so "Release 1.0" stays a
    /// Markdown file ("Release 1.0.md") rather than turning into a ".0" file
    /// the sidebar no longer lists. A folder takes the name exactly.
    static func renamedName(_ proposed: String, from current: String,
                            isDirectory: Bool) throws -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"),
              !trimmed.hasPrefix(".")
        else { throw OrganiseError.invalidName }
        guard !isDirectory, DocumentKind(fileName: trimmed) == nil else { return trimmed }
        let existing = (current as NSString).pathExtension
        return existing.isEmpty ? trimmed : "\(trimmed).\(existing)"
    }

    /// Removes a document. A local file goes to the Trash — recoverable, and
    /// what a Mac user expects, which is why nothing asks first. A document in
    /// a repository is removed by a commit instead: still recoverable, but
    /// only through git, so the caller asks first.
    func delete(_ id: DocumentID) async throws {
        guard let source = source(id.sourceID), let store = store(for: id.sourceID)
        else { throw OrganiseError.notAllowed }
        // Nothing may be written to the document once it's on its way out —
        // an autosave landing after the delete recreated the file in place.
        let affected = documentCache.filter { $0.key.isWithin(id) }.values
        for document in affected {
            document.detach()
            await document.waitForSave()
        }
        do {
            try await store.delete(id)
        } catch {
            for document in affected { document.reattach() }
            throw error
        }
        if source.kind == .looseFiles, let url = self.url(for: id) {
            // Removing it should also stop it being listed.
            looseFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        }
        relocate(from: id, to: nil)
        if source.kind == .looseFiles {
            refreshLooseFiles()
        } else if let parent = id.parent {
            loadChildren(of: parent, force: true)
        }
    }

    /// True when removing this document is not undoable from the Finder — a
    /// repository commit rather than the Trash, so the UI asks first.
    func deletionNeedsConfirmation(_ id: DocumentID) -> Bool {
        source(id.sourceID)?.isLocal == false
    }

    /// Loose files only: stop listing it without touching the file itself.
    func removeFromOpenedFiles(_ id: DocumentID) {
        guard let url = self.url(for: id) else { return }
        looseFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        relocate(from: id, to: nil)
        refreshLooseFiles()
    }

    /// Drops cached state for an item and everything under it, then tells the
    /// windows so their selection and open folders follow.
    private func relocate(from: DocumentID, to: DocumentID?) {
        for key in documentCache.keys where key.isWithin(from) {
            // Windows may still hold the old model until they remap; it must
            // not write to where the document used to be.
            documentCache[key]?.detach()
            documentCache[key] = nil
        }
        for key in childrenByDirectory.keys where key.isWithin(from) {
            childrenByDirectory[key] = nil
        }
        documentMoved.send((from: from, to: to))
    }

    // MARK: File-system monitoring

    /// One recursive watcher per source root, so a file dropped into a
    /// subfolder by Finder, a sync client or a git checkout appears straight
    /// away rather than on the next reactivation.
    private func startMonitor(for source: Source) {
        guard source.kind == .localFolder, let root = source.rootURL else { return }
        let id = source.id
        monitors[id]?.stop()
        monitors[id] = DirectoryWatcher(
            root: root,
            onChange: { [weak self] directories, includesSubfolders in
                self?.directoriesChanged(directories, includesSubfolders: includesSubfolders, in: id)
            },
            onRootLost: { [weak self] in
                self?.rootChanged(for: id)
            })
    }

    /// The root folder of a local source was renamed, moved, deleted or
    /// unmounted. Its bookmark still finds a folder that was renamed or
    /// moved, so the source follows it: the watcher, the listing and the
    /// store behind each open document move to the new path, and the name
    /// follows the folder. Until now the old path was watched on, and the
    /// sidebar showed the old name, until the next launch. A folder that is
    /// gone, or in the Trash, is missing until it comes back.
    func rootChanged(for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              sources[index].kind == .localFolder else { return }
        let old = sources[index].rootURL
        if let bookmark = sourceBookmarks[id], let url = resolveBookmark(bookmark),
           url.resolvingSymlinksInPath().path != old?.resolvingSymlinksInPath().path,
           FileManager.default.fileExists(atPath: url.path), !Self.isInTrash(url) {
            sources[index].rootURL = url
            sources[index].name = url.lastPathComponent
            sources[index].status = .ready
            startMonitor(for: sources[index])
            persistSources()
            // Open documents keep their text and edits; they save to the
            // folder's new place from now on.
            if let store = store(for: id) {
                for (key, document) in documentCache where key.sourceID == id {
                    document.replaceStore(store)
                }
            }
            for key in childrenByDirectory.keys where key.sourceID == id {
                loadChildren(of: key, force: true)
            }
            return
        }
        let path = sources[index].rootURL?.path
        sources[index].status = (path.map { FileManager.default.fileExists(atPath: $0) } ?? false)
            ? .ready : .missing
    }

    /// A folder moved to the Trash is gone as far as the sidebar is
    /// concerned, even though its bookmark still finds it there.
    private static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Reloads only the directories the sidebar has actually read. A change
    /// deep inside a folder nobody has expanded needs no work — it will be
    /// read correctly whenever it is first opened.
    private func directoriesChanged(_ directories: [URL], includesSubfolders: Bool = false,
                                    in sourceID: UUID) {
        guard let source = source(sourceID) else { return }
        for directory in directories {
            guard let id = source.documentID(for: directory) else { continue }
            // FSEvents lost track of what changed below here: re-read every
            // folder of it that is on screen, not just this one.
            if includesSubfolders {
                for loaded in childrenByDirectory.keys where loaded.isWithin(id) && loaded != id {
                    loadChildren(of: loaded, force: true)
                }
                for (key, document) in documentCache where key.isWithin(id) {
                    document.reconcileWithDisk()
                }
            }
            // Open documents in a changed folder pick up edits made by other
            // programs now, not only when the app next comes to the front.
            for (key, document) in documentCache where key.parent == id {
                document.reconcileWithDisk()
            }
            if childrenByDirectory[id] != nil {
                loadChildren(of: id, force: true)
            }
            // A rename reports the *containing* directory for the new name but
            // can leave the old entry's parent stale, so refresh that too.
            if let parent = id.parent, childrenByDirectory[parent] != nil {
                loadChildren(of: parent, force: true)
            }
        }
    }

    // MARK: Persistence

    private static let sourcesKey = "sources"
    private static let looseFilesKey = "looseFiles"
    private static let recentItemsKey = "recentItems"
    private static let maxRecentItems = 12
    /// Pre-sources keys, read once to migrate and then left alone.
    private static let legacyWorkspaceKey = "workspaceBookmark"

    /// The last bookmark each local source was saved with. A folder on an
    /// unplugged drive can't be bookmarked afresh, and without this the next
    /// save of the list (adding another folder, reordering) dropped it for good.
    private var sourceBookmarks: [UUID: Data] = [:]
    /// Saved sources whose bookmark didn't resolve at launch — a volume not
    /// mounted yet, say. Written back untouched so they return with it.
    private var unresolvedSourceRecords: [SourceRecord] = []
    /// The last bookmark each opened file was saved with, for the same reason.
    private var looseBookmarks: [URL: Data] = [:]
    /// Opened files on a volume that isn't mounted. Kept out of the list but
    /// saved, so they come back with the drive instead of being forgotten
    /// the first time the app is brought forward without it.
    private var unavailableLooseBookmarks: [Data] = []

    private struct SourceRecord: Codable {
        let id: UUID
        let name: String
        /// Local folders only; a repository is named, not bookmarked.
        var bookmark: Data?
        var repository: Source.Repository?
    }

    private func persistSources() {
        let records: [SourceRecord] = sources.compactMap { source in
            switch source.kind {
            case .localFolder:
                let fresh = try? source.rootURL?.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                guard let bookmark = fresh ?? sourceBookmarks[source.id] else { return nil }
                sourceBookmarks[source.id] = bookmark
                return SourceRecord(id: source.id, name: source.name, bookmark: bookmark)
            case .gitHub:
                guard let repository = source.repository else { return nil }
                return SourceRecord(id: source.id, name: source.name,
                                    bookmark: nil, repository: repository)
            case .looseFiles:
                return nil
            }
        }
        let kept = unresolvedSourceRecords.filter { record in !sources.contains { $0.id == record.id } }
        guard let data = try? JSONEncoder().encode(records + kept) else { return }
        UserDefaults.standard.set(data, forKey: Self.sourcesKey)
    }

    private func persistLooseFiles() {
        let bookmarks: [Data] = looseFiles.compactMap { url in
            let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
            guard let bookmark = fresh ?? looseBookmarks[url.standardizedFileURL] else { return nil }
            looseBookmarks[url.standardizedFileURL] = bookmark
            return bookmark
        }
        UserDefaults.standard.set(bookmarks + unavailableLooseBookmarks, forKey: Self.looseFilesKey)
    }

    /// Where removable and network volumes are mounted. Tests point it at a
    /// folder of their own.
    static var volumesDirectory = "/Volumes"

    /// True for a file on a volume that isn't mounted right now. Such a file
    /// is away, not gone.
    static func isOnUnmountedVolume(_ url: URL) -> Bool {
        // resolvingSymlinksInPath drops a leading /private only from a path
        // that exists, and a file on an unmounted volume doesn't.
        func components(_ url: URL) -> [String] {
            var parts = url.resolvingSymlinksInPath().pathComponents
            if parts.count > 1, parts[1] == "private" { parts.remove(at: 1) }
            return parts
        }
        let volumes = components(URL(fileURLWithPath: volumesDirectory))
        let parts = components(url)
        guard parts.count > volumes.count, Array(parts.prefix(volumes.count)) == volumes else { return false }
        let volume = NSString.path(withComponents: Array(parts.prefix(volumes.count + 1)))
        return !FileManager.default.fileExists(atPath: volume)
    }

    private func restoreSources() {
        if let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
           let records = try? JSONDecoder().decode([SourceRecord].self, from: data) {
            for record in records {
                if let repository = record.repository {
                    sources.append(Source(id: record.id, kind: .gitHub,
                                          name: record.name, rootURL: nil,
                                          repository: repository))
                    continue
                }
                guard let bookmark = record.bookmark else { continue }
                guard let url = resolveBookmark(bookmark) else {
                    unresolvedSourceRecords.append(record)
                    continue
                }
                sourceBookmarks[record.id] = bookmark
                // The name follows the folder: renamed in Finder, it came
                // back under its old name on every launch.
                var source = Source(id: record.id, kind: .localFolder,
                                    name: url.lastPathComponent, rootURL: url)
                source.status = FileManager.default.fileExists(atPath: url.path)
                    ? .ready : .missing
                sources.append(source)
            }
        } else {
            migrateLegacyWorkspace()
        }

        let savedLooseFiles = UserDefaults.standard.array(forKey: Self.looseFilesKey) as? [Data] ?? []
        for bookmark in savedLooseFiles {
            guard let url = resolveBookmark(bookmark),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
                if let path, Self.isOnUnmountedVolume(URL(fileURLWithPath: path)) {
                    unavailableLooseBookmarks.append(bookmark)
                }
                continue
            }
            // A file that now sits inside an added folder belongs there.
            guard !sources.contains(where: { $0.kind == .localFolder && $0.documentID(for: url) != nil })
            else { continue }
            looseFiles.append(url)
            looseBookmarks[url.standardizedFileURL] = bookmark
        }
        if !looseFiles.isEmpty { ensureLooseFilesSource() }
        // A stale bookmark still resolves, but macOS asks for it to be made
        // again while it still can be; left alone it eventually stops working.
        if foundStaleBookmark { persistSources() }
        startWatchingAndReadSourcesSoon()
    }

    /// The rest of restoring a source — an FSEvents watcher per local root and
    /// the first read of each tree — deferred to the next turn of the main
    /// loop so the window is on screen before any of it runs.
    ///
    /// It is all blocking work on the main thread: FSEventStreamCreate opens
    /// every ancestor directory of the root, and reading a GitHub source's
    /// tree reaches the Keychain for the token. Done from `init`, a slow
    /// volume or a Keychain prompt meant the app came up with NO WINDOW AT
    /// ALL — alive, showing nothing, with no way to tell what it was waiting
    /// on (observed twice). Deferring doesn't make the calls fast, but it
    /// puts a window in front of them, so the worst case is a populated
    /// sidebar arriving late rather than an app that appears not to launch.
    private func startWatchingAndReadSourcesSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only the restored ones: a folder added in the meantime has
            // its watcher already, and replacing it drops whatever that
            // one was about to report.
            for source in self.sources where source.kind == .localFolder && self.monitors[source.id] == nil {
                self.startMonitor(for: source)
            }
            for source in self.sources {
                self.loadChildren(of: DocumentID(sourceID: source.id, path: ""))
            }
        }
    }

    /// One-time upgrade from the single-workspace model: the old workspace
    /// folder becomes the first source.
    private func migrateLegacyWorkspace() {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyWorkspaceKey),
              let url = resolveBookmark(data),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        let source = Source(id: UUID(), kind: .localFolder,
                            name: url.lastPathComponent, rootURL: url)
        sources.append(source)
        startMonitor(for: source)
        persistSources()
    }

    /// Resolves a security-scoped bookmark and opens its scope for the app's
    /// lifetime — sources and loose files are needed for as long as they're
    /// listed, so there is nothing to balance here.
    private var foundStaleBookmark = false

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return nil }
        if stale { foundStaleBookmark = true }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func saveBookmark(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return }
        rememberRecent(RecentItem(bookmark: bookmark, path: url.path,
                                  isDirectory: Self.isDirectory(url)))
    }

    // MARK: Recent items (File ▸ Open Recent)

    /// Newest first. Folders belong here as much as files — a folder is this
    /// app's unit of work, so "reopen the folder I was in last week" is the
    /// common case and reopening a single file the exception.
    struct RecentItem: Identifiable, Codable, Equatable {
        let bookmark: Data
        /// Kept beside the bookmark purely so the menu can be drawn without
        /// resolving every entry — resolving opens a sandbox scope per item,
        /// which is far too much work for showing a list of names. Treated as
        /// display-only: it may be stale, and opening always goes through the
        /// bookmark.
        let path: String
        let isDirectory: Bool

        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { url.lastPathComponent }
        var parentName: String { url.deletingLastPathComponent().lastPathComponent }
    }

    var recentFolders: [RecentItem] { recentItems.filter(\.isDirectory) }
    var recentFiles: [RecentItem] { recentItems.filter { !$0.isDirectory } }

    private func rememberRecent(_ item: RecentItem) {
        var items = recentItems.filter { $0.path != item.path }
        items.insert(item, at: 0)
        recentItems = Array(items.prefix(Self.maxRecentItems))
        persistRecents()
    }

    private func loadRecents() -> [RecentItem] {
        guard let data = UserDefaults.standard.data(forKey: Self.recentItemsKey),
              let items = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return [] }
        return items
    }

    private func persistRecents() {
        guard let data = try? JSONEncoder().encode(recentItems) else { return }
        UserDefaults.standard.set(data, forKey: Self.recentItemsKey)
    }

    /// Opens a menu entry. An entry whose file has since been moved, deleted,
    /// or had its grant revoked drops off the list rather than failing
    /// silently every time it's picked.
    func openRecent(_ item: RecentItem) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else {
            forgetRecent(item)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            forgetRecent(item)
            return
        }
        // Something already listed has its own grant; this one would only
        // pile up (a sandboxed app has a limit on open scopes).
        let standardized = url.standardizedFileURL
        let listed = sources.contains { $0.rootURL?.standardizedFileURL == standardized }
            || looseFiles.contains { $0.standardizedFileURL == standardized }
            || sources.contains { $0.kind == .localFolder && $0.documentID(for: url) != nil }
        openExternal([url])
        if listed { url.stopAccessingSecurityScopedResource() }
    }

    func clearRecents() {
        recentItems = []
        persistRecents()
    }

    private func forgetRecent(_ item: RecentItem) {
        recentItems.removeAll { $0.path == item.path }
        persistRecents()
    }
}

/// Why renaming, deleting or creating something in the sidebar didn't happen.
/// Store failures (a full disk, a refused commit) come through as they are.
enum OrganiseError: LocalizedError, Equatable {
    case notAllowed
    case invalidName
    case nameTaken(String)
    case unresolvedConflict

    var errorDescription: String? {
        switch self {
        case .notAllowed:
            return String(localized: "This item can't be changed here.")
        case .invalidName:
            return String(localized: "A name can't be empty, start with a dot, or contain \"/\" or \":\".")
        case .nameTaken(let name):
            return String(localized: "\"\(name)\" is already taken. Choose a different name.")
        case .unresolvedConflict:
            return String(localized: "This document changed elsewhere while you were editing it. Resolve that first, then rename it.")
        }
    }
}
