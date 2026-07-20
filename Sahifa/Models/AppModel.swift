import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Workspace state: a user-chosen folder of plain .md files, browsed in the
/// sidebar. Sandboxed access persists across launches via a security-scoped
/// bookmark.
@MainActor
final class AppModel: ObservableObject {
    /// Single instance: the SwiftUI scene owns it as a StateObject, and the
    /// app delegate reaches it for Finder open events (application(_:open:)).
    static let shared = AppModel()

    @Published private(set) var workspaceURL: URL?
    @Published private(set) var files: [URL] = []

    /// One DocumentModel per file, shared by every window showing it.
    private var documentCache: [URL: DocumentModel] = [:]

    private var monitor: DispatchSourceFileSystemObject?
    /// Files opened individually (panel, Finder, drag-drop) rather than via a
    /// folder; kept listed even when the sandbox can't read their parent.
    private var standaloneFiles: [URL] = []
    private static let bookmarkKey = "workspaceBookmark"

    /// Which window's state receives externally opened files (last key
    /// window; see KeyWindowTracker in ContentView).
    weak var frontWindowState: WindowState?
    /// External open that arrived before any window attached (cold launch via
    /// Finder); consumed by the first WindowState.attach.
    private var pendingSelection: URL?

    /// Fires only when the user *deliberately* switches workspace folder
    /// (Open Folder…), so every window adopts the new folder. Opening an
    /// individual file also changes `workspaceURL` — but that must NOT move
    /// other windows, so it deliberately does not fire this.
    let workspaceDidChange = PassthroughSubject<Void, Never>()

    init() {
        // Dev convenience: `Sahifa -workspace /path` opens a folder or a
        // single Markdown file directly (useful for testing; under the
        // sandbox, arbitrary paths only resolve when access is otherwise
        // granted).
        if let index = CommandLine.arguments.firstIndex(of: "-workspace"),
           index + 1 < CommandLine.arguments.count {
            openItem(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else {
            restoreWorkspace()
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
        // typing into a stale document.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for document in self.documentCache.values {
                    document.reconcileWithDisk()
                }
                self.refreshFiles()
            }
        }
    }

    // MARK: Workspace

    /// Folder and file opening are separate panels on purpose: a combined
    /// panel (canChooseFiles + canChooseDirectories + content-type filter)
    /// makes the Open button descend into a highlighted folder instead of
    /// choosing it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(url)
        openItem(url)
        workspaceDidChange.send()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.markdownTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Same routing as a Finder open: the file lands in the window that
        // asked for it, and no other window is disturbed.
        openExternal([url])
    }

    /// Three slots, each with a distinct job: the folder keeps the sidebar's
    /// listing across launches, the recent-file list keeps sandbox access to
    /// files opened individually, and last-opened records what to actually
    /// restore. Folding these together loses something either way — one slot
    /// makes every file open forget the folder, while keying restore off the
    /// folder alone makes a file opened from Finder vanish on relaunch.
    private func saveBookmark(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return }
        UserDefaults.standard.set(bookmark, forKey: Self.lastOpenedKey)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            ?? url.hasDirectoryPath
        if isDirectory {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } else {
            var recent = UserDefaults.standard.array(forKey: Self.fileBookmarksKey) as? [Data] ?? []
            recent.removeAll { $0 == bookmark }
            recent.append(bookmark)
            UserDefaults.standard.set(recent.suffix(Self.maxRecentFiles).map { $0 },
                                      forKey: Self.fileBookmarksKey)
        }
    }

    private static let markdownTypes: [UTType] =
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }

    /// What counts as openable, for every path that takes a file from outside
    /// the app (Finder, drag-drop). Matches the extensions declared in
    /// `UTImportedTypeDeclarations`; keep the two in step.
    static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mkdn"]

    /// Opens either a folder (workspace) or a single Markdown file. For a
    /// file, the workspace becomes its parent folder; under the sandbox the
    /// grant covers only the file itself, so the sidebar may list just it.
    private func openItem(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            ?? url.hasDirectoryPath
        if isDirectory {
            standaloneFiles = []
            setWorkspace(url)
        } else {
            if !standaloneFiles.contains(url) { standaloneFiles.append(url) }
            let parent = url.deletingLastPathComponent()
            if workspaceURL == parent {
                refreshFiles()
            } else {
                setWorkspace(parent)
            }
        }
    }

    /// Entry point for files/folders arriving from outside the app's own
    /// panels: Finder "Open With", double-click, Dock-icon drops
    /// (application(_:open:)) and window drag-drop. These URLs carry an
    /// implicit sandbox grant; the bookmark persists it across launches.
    /// Selection goes to `preferring` (the drop-target window) or the last
    /// key window; with no window yet (cold launch), the first window to
    /// attach picks it up.
    func openExternal(_ urls: [URL], preferring target: WindowState? = nil) {
        var openedFile: URL?
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? url.hasDirectoryPath
            let isMarkdown = Self.markdownExtensions.contains(url.pathExtension.lowercased())
            guard isDirectory || isMarkdown else { continue }
            saveBookmark(url)
            openItem(url)
            if !isDirectory { openedFile = url }
        }
        guard let file = openedFile else { return }
        if let windowState = target ?? frontWindowState {
            windowState.selectedFile = file
        } else {
            pendingSelection = file
        }
    }

    /// What a new window should open first.
    var defaultSelection: URL? {
        standaloneFiles.last ?? files.first
    }

    /// One-shot: an external open that arrived before any window existed.
    func takePendingSelection() -> URL? {
        defer { pendingSelection = nil }
        return pendingSelection
    }

    private static let fileBookmarksKey = "recentFileBookmarks"
    private static let lastOpenedKey = "lastOpenedBookmark"
    private static let maxRecentFiles = 10

    private func restoreWorkspace() {
        // Reading a bookmark's file requires its security scope to be open, so
        // every candidate gets opened and the ones we don't keep are closed
        // again at the end — otherwise each launch strands a sandbox extension
        // per remembered file.
        var opened: [URL] = []

        let folderData = UserDefaults.standard.data(forKey: Self.bookmarkKey)
        if let folderData, let url = resolveBookmark(folderData, opened: &opened) {
            openItem(url)
        }
        // Only recent files living in the restored workspace get listed (oldest
        // first, so the newest ends up as `defaultSelection`).
        let recent = UserDefaults.standard.array(forKey: Self.fileBookmarksKey) as? [Data] ?? []
        var existing: [URL] = []
        for data in recent {
            guard let url = resolveBookmark(data, opened: &opened),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            existing.append(url)
        }
        if let workspace = workspaceURL {
            for url in existing
            where url.deletingLastPathComponent() == workspace && !standaloneFiles.contains(url) {
                standaloneFiles.append(url)
            }
            refreshFiles()
        }
        // Whatever was opened last is what the app comes back to — and if that
        // was a file from another folder, it brings its folder with it. Skipped
        // when it *is* the folder above, which is already open: re-opening it
        // would clear the standalone list just built.
        if let data = UserDefaults.standard.data(forKey: Self.lastOpenedKey), data != folderData,
           let url = resolveBookmark(data, opened: &opened),
           FileManager.default.fileExists(atPath: url.path) {
            openItem(url)
            // `defaultSelection` takes the newest standalone file.
            if let index = standaloneFiles.firstIndex(of: url) {
                standaloneFiles.append(standaloneFiles.remove(at: index))
            }
        }
        if workspaceURL == nil, let last = existing.last {
            standaloneFiles = [last]
            setWorkspace(last.deletingLastPathComponent())
        }
        // What we kept — the workspace folder and the files still listed —
        // stays open for the app's lifetime, which is what those grants are for.
        for url in opened where url != workspaceURL && !standaloneFiles.contains(url) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Resolves a security-scoped bookmark and opens its scope. URLs whose
    /// scope actually opened are appended to `opened`, so the caller can close
    /// the ones it discards — `stopAccessing…` must only balance a `start`
    /// that returned true.
    private func resolveBookmark(_ data: Data, opened: inout [URL]) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return nil }
        if url.startAccessingSecurityScopedResource() {
            opened.append(url)
        }
        return url
    }

    private func setWorkspace(_ url: URL) {
        monitor?.cancel()
        monitor = nil
        workspaceURL = url
        // Standalone entries exist to keep sandbox-opened files visible when
        // their own folder isn't readable — they belong to this workspace
        // only. Leaving stale ones in would list files from a folder the user
        // has moved on from.
        standaloneFiles.removeAll { $0.deletingLastPathComponent() != url }
        refreshFiles()
        startMonitor(url)
    }

    func refreshFiles() {
        guard let dir = workspaceURL else {
            files = []
            return
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        files = contents
            .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // Sandboxed single-file opens: the parent folder isn't readable, but
        // the files themselves are — keep them listed.
        for lone in standaloneFiles.reversed()
        where !files.contains(lone) && FileManager.default.fileExists(atPath: lone.path) {
            files.insert(lone, at: 0)
        }
    }

    // MARK: Documents

    func document(for url: URL) -> DocumentModel {
        if let existing = documentCache[url] {
            return existing
        }
        let document = DocumentModel(url: url)
        documentCache[url] = document
        return document
    }

    /// Creates an empty Untitled file and returns its URL (for the invoking
    /// window to select).
    @discardableResult
    func newFile() -> URL? {
        guard let dir = workspaceURL else { return nil }
        let base = String(localized: "Untitled")
        var candidate = dir.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        do {
            try "".write(to: candidate, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        refreshFiles()
        return candidate
    }

    func saveAll() {
        for document in documentCache.values {
            document.saveNow()
        }
    }

    // MARK: File-system monitoring

    private func startMonitor(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshFiles() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        monitor = source
    }
}
