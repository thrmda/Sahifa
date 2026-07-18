import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Workspace state: a user-chosen folder of plain .md files, browsed in the
/// sidebar. Sandboxed access persists across launches via a security-scoped
/// bookmark.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var files: [URL] = []

    /// One DocumentModel per file, shared by every window showing it.
    private var documentCache: [URL: DocumentModel] = [:]

    private var monitor: DispatchSourceFileSystemObject?
    /// Set when the user opened a single file rather than a folder.
    private var standaloneFile: URL?
    private static let bookmarkKey = "workspaceBookmark"

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
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.markdownTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(url)
        openItem(url)
    }

    private func saveBookmark(_ url: URL) {
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    private static let markdownTypes: [UTType] =
        [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }

    /// Opens either a folder (workspace) or a single Markdown file. For a
    /// file, the workspace becomes its parent folder; under the sandbox the
    /// grant covers only the file itself, so the sidebar may list just it.
    private func openItem(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            ?? url.hasDirectoryPath
        if isDirectory {
            standaloneFile = nil
            setWorkspace(url)
        } else {
            standaloneFile = url
            setWorkspace(url.deletingLastPathComponent())
        }
    }

    /// What a new window should open first.
    var defaultSelection: URL? {
        standaloneFile ?? files.first
    }

    private func restoreWorkspace() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return }
        _ = url.startAccessingSecurityScopedResource()
        openItem(url)
    }

    private func setWorkspace(_ url: URL) {
        monitor?.cancel()
        monitor = nil
        workspaceURL = url
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
        // Sandboxed single-file open: the parent folder isn't readable, but
        // the file itself is — keep it listed.
        if let lone = standaloneFile, !files.contains(lone),
           FileManager.default.fileExists(atPath: lone.path) {
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
