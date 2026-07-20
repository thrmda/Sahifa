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

    /// One DocumentModel per document, shared by every window showing it.
    private var documentCache: [DocumentID: DocumentModel] = [:]

    /// One per local source root: catches files added or removed at the top
    /// level. Deeper directories refresh when expanded and when the app is
    /// reactivated (see the didBecomeActive observer).
    private var monitors: [UUID: DispatchSourceFileSystemObject] = [:]

    /// Which window's state receives externally opened documents (last key
    /// window; see KeyWindowTracker in ContentView).
    weak var frontWindowState: WindowState?
    /// External open that arrived before any window attached (cold launch via
    /// Finder); consumed by the first WindowState.attach.
    private var pendingSelection: DocumentID?

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
        panel.allowedContentTypes = Self.markdownTypes
        guard panel.runModal() == .OK else { return }
        openExternal(panel.urls)
    }

    private static let markdownTypes: [UTType] =
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }

    /// What counts as openable, for every path that takes a file from outside
    /// the app (Finder, drag-drop). Matches the extensions declared in
    /// `UTImportedTypeDeclarations`; keep the two in step.
    static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mkdn"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }

    /// Entry point for anything arriving from outside the app's own panels:
    /// Finder "Open With", double-click, Dock-icon drops, drag-drop, and the
    /// Open panels above. Folders become sources; files are selected where
    /// they already live, or filed under loose files.
    func openExternal(_ urls: [URL], preferring target: WindowState? = nil) {
        var opened: DocumentID?
        for url in urls {
            if Self.isDirectory(url) {
                addFolderSource(url)
            } else if Self.isMarkdown(url) {
                opened = adoptFile(url)
            }
        }
        guard let document = opened else { return }
        if let windowState = target ?? frontWindowState {
            windowState.selection = document
        } else {
            pendingSelection = document
        }
    }

    @discardableResult
    private func addFolderSource(_ url: URL) -> Source? {
        saveBookmark(url)
        // Already added: refresh it rather than listing the same folder twice.
        if let existing = sources.first(where: {
            $0.kind == .localFolder && $0.rootURL.standardizedFileURL == url.standardizedFileURL
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

    func removeSource(_ id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let source = sources[index]
        monitors[id]?.cancel()
        monitors[id] = nil
        sources.remove(at: index)
        childrenByDirectory = childrenByDirectory.filter { $0.key.sourceID != id }
        if source.kind == .looseFiles {
            looseFiles = []
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
        let directory = source.url(for: id)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        var nodes: [Node] = []
        for url in contents {
            let isDirectory = Self.isDirectory(url)
            guard isDirectory || Self.isMarkdown(url) else { continue }
            nodes.append(Node(id: id.appending(url.lastPathComponent),
                              name: url.lastPathComponent,
                              isDirectory: isDirectory))
        }
        // Folders first, then files; each alphabetical the way Finder sorts.
        childrenByDirectory[id] = nodes.sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
    }

    private func looseFileNodes() -> [Node] {
        let source = looseSource()
        return looseFiles.compactMap { url in
            guard let id = source.documentID(for: url) else { return nil }
            return Node(id: id, name: url.lastPathComponent, isDirectory: false)
        }
    }

    private func refreshLooseFiles() {
        looseFiles.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
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
            let exists = FileManager.default.fileExists(atPath: sources[index].rootURL.path)
            sources[index].status = exists ? .ready : .missing
        }
        for id in childrenByDirectory.keys where id.sourceID != Source.looseFilesID {
            loadChildren(of: id, force: true)
        }
        refreshLooseFiles()
    }

    // MARK: Documents

    func document(for id: DocumentID) -> DocumentModel? {
        if let existing = documentCache[id] { return existing }
        guard let url = url(for: id) else { return nil }
        let document = DocumentModel(id: id, url: url)
        documentCache[id] = document
        return document
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

    /// Creates an empty Untitled file inside `directory` (a source root or any
    /// folder in the tree) and returns its ID for the invoking window.
    @discardableResult
    func newFile(in directory: DocumentID?) -> DocumentID? {
        guard let target = directory ?? firstWritableDirectory(),
              let source = source(target.sourceID), source.kind == .localFolder
        else { return nil }
        let folder = source.url(for: target)
        let base = String(localized: "Untitled")
        var name = "\(base).md"
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
            name = "\(base) \(counter).md"
            counter += 1
        }
        do {
            try "".write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        loadChildren(of: target, force: true)
        return target.appending(name)
    }

    private func firstWritableDirectory() -> DocumentID? {
        sources.first { $0.kind == .localFolder }
            .map { DocumentID(sourceID: $0.id, path: "") }
    }

    var canCreateFiles: Bool {
        sources.contains { $0.kind == .localFolder }
    }

    func saveAll() {
        for document in documentCache.values {
            document.saveNow()
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
    @discardableResult
    func rename(_ id: DocumentID, to proposed: String) -> DocumentID? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix("."),
              let source = source(id.sourceID), source.kind == .localFolder,
              let parent = id.parent
        else { return nil }

        let oldURL = source.url(for: id)
        var name = trimmed
        if (name as NSString).pathExtension.isEmpty {
            let existing = (id.path as NSString).pathExtension
            if !existing.isEmpty { name += ".\(existing)" }
        }
        guard name != id.name else { return nil }
        let newURL = source.url(for: parent).appending(path: name)
        guard !FileManager.default.fileExists(atPath: newURL.path) else { return nil }

        // Flush pending edits before the file moves out from under them.
        documentCache[id]?.saveNow()
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            return nil
        }
        let newID = parent.appending(name)
        relocate(from: id, to: newID)
        loadChildren(of: parent, force: true)
        return newID
    }

    /// Moves to Trash rather than deleting: recoverable, and the macOS
    /// convention, which is also why there's no confirmation prompt.
    func moveToTrash(_ id: DocumentID) {
        guard let source = source(id.sourceID), let url = self.url(for: id) else { return }
        if source.kind == .looseFiles {
            // Trashing it should also stop it being listed.
            looseFiles.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        relocate(from: id, to: nil)
        if source.kind == .looseFiles {
            refreshLooseFiles()
        } else if let parent = id.parent {
            loadChildren(of: parent, force: true)
        }
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
            documentCache[key] = nil
        }
        for key in childrenByDirectory.keys where key.isWithin(from) {
            childrenByDirectory[key] = nil
        }
        documentMoved.send((from: from, to: to))
    }

    // MARK: File-system monitoring

    /// One watcher per source root. Deeper directories are re-read on expand
    /// and on app activation instead of holding a descriptor each — a real
    /// notes tree would otherwise cost hundreds of open files.
    private func startMonitor(for source: Source) {
        guard source.kind == .localFolder else { return }
        let descriptor = open(source.rootURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        let id = source.id
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.loadChildren(of: DocumentID(sourceID: id, path: ""), force: true)
            }
        }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        monitors[id]?.cancel()
        monitors[id] = watcher
    }

    // MARK: Persistence

    private static let sourcesKey = "sources"
    private static let looseFilesKey = "looseFiles"
    private static let recentItemsKey = "recentItems"
    private static let maxRecentItems = 12
    /// Pre-sources keys, read once to migrate and then left alone.
    private static let legacyWorkspaceKey = "workspaceBookmark"

    private struct SourceRecord: Codable {
        let id: UUID
        let name: String
        let bookmark: Data
    }

    private func persistSources() {
        let records: [SourceRecord] = sources.compactMap { source in
            guard source.kind == .localFolder,
                  let bookmark = try? source.rootURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
            else { return nil }
            return SourceRecord(id: source.id, name: source.name, bookmark: bookmark)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.sourcesKey)
    }

    private func persistLooseFiles() {
        let bookmarks: [Data] = looseFiles.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope,
                                 includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: Self.looseFilesKey)
    }

    private func restoreSources() {
        if let data = UserDefaults.standard.data(forKey: Self.sourcesKey),
           let records = try? JSONDecoder().decode([SourceRecord].self, from: data) {
            for record in records {
                guard let url = resolveBookmark(record.bookmark) else { continue }
                var source = Source(id: record.id, kind: .localFolder,
                                    name: record.name, rootURL: url)
                source.status = FileManager.default.fileExists(atPath: url.path)
                    ? .ready : .missing
                sources.append(source)
                startMonitor(for: source)
            }
        } else {
            migrateLegacyWorkspace()
        }

        let looseBookmarks = UserDefaults.standard.array(forKey: Self.looseFilesKey) as? [Data] ?? []
        for bookmark in looseBookmarks {
            guard let url = resolveBookmark(bookmark),
                  FileManager.default.fileExists(atPath: url.path),
                  // A file that now sits inside an added folder belongs there.
                  !sources.contains(where: {
                      $0.kind == .localFolder && $0.documentID(for: url) != nil
                  })
            else { continue }
            looseFiles.append(url)
        }
        if !looseFiles.isEmpty { ensureLooseFilesSource() }
        for source in sources {
            loadChildren(of: DocumentID(sourceID: source.id, path: ""))
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
    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return nil }
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
        openExternal([url])
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
