import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var windowState = WindowState()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.layoutDirection) private var layoutDirection

    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0
    @State private var dragStartSidebarWidth: Double?

    private static let minSidebar: CGFloat = 170
    private static let maxSidebar: CGFloat = 420

    var body: some View {
        // Not NavigationSplitView: under forced-RTL chrome it mirrors the
        // sidebar to the trailing edge but KEEPS reserving the sidebar's
        // width on the leading edge — a phantom sidebar-width gutter that
        // squeezes the whole detail area. A plain HStack mirrors correctly.
        HStack(spacing: 0) {
            if windowState.sidebarVisible {
                SidebarView()
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))
                sidebarResizeHandle
            }
            detail
                .frame(maxWidth: .infinity)
        }
        .environmentObject(windowState)
        .focusedSceneObject(windowState)
        .navigationTitle(Text(verbatim: windowState.document?.displayName ?? "Sahifa"))
        // Finder-style drops anywhere on the window open the file/folder.
        // Drops can land on a non-key window, so target THIS window's state.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var accepted = false
            for provider in providers
            where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        model.openExternal([url], preferring: windowState)
                    }
                }
            }
            return accepted
        }
        // Finder "Open With"/Dock drops land on the frontmost window.
        .background(KeyWindowTracker { model.frontWindowState = windowState })
        .onAppear {
            model.frontWindowState = windowState
            windowState.attach(model)
            Exporter.shared.handleCLIFlagsIfPresent(markdown: windowState.document?.text,
                                                    title: windowState.document?.exportName ?? "Untitled")
            applyDevWindowFlags(model: model, windowState: windowState,
                                openWindow: { openWindow(id: "main") },
                                openSettings: { openSettings() })
        }
        // Toolbar lives on the split view, not the sidebar column — items
        // attached to the sidebar leave the toolbar when the column collapses.
        .toolbar {
            // Explicit placement: with .automatic, forced-RTL chrome
            // (uiLanguage = "ar") confuses NSToolbar's layout and the items
            // end up collapsed into the overflow menu.
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { windowState.sidebarVisible.toggle() }
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .help(Text("Toggle Sidebar"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .help(Text("Add Folder…"))
                Button {
                    model.chooseFile()
                } label: {
                    Label("Open File…", systemImage: "doc")
                }
                .help(Text("Open File…"))
                Button {
                    Task {
                        if let id = await model.newFile(in: windowState.newFileTarget) {
                            windowState.selection = id
                        }
                    }
                } label: {
                    Label("New File", systemImage: "square.and.pencil")
                }
                .disabled(!model.canCreateFiles)
                .help(Text("New File"))
            }
        }
    }

    /// Draggable divider that resizes the sidebar. The width is persisted, so
    /// it survives relaunches and applies to every window.
    private var sidebarResizeHandle: some View {
        Divider()
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartSidebarWidth ?? sidebarWidth
                        dragStartSidebarWidth = base
                        // translation is physical; in RTL chrome the sidebar
                        // sits on the trailing (right) edge, so dragging left
                        // grows it.
                        let physical = value.translation.width
                        let delta = layoutDirection == .rightToLeft ? -physical : physical
                        sidebarWidth = min(max(base + delta, Double(Self.minSidebar)),
                                           Double(Self.maxSidebar))
                    }
                    .onEnded { _ in dragStartSidebarWidth = nil }
            )
    }

    @ViewBuilder
    private var detail: some View {
        if let document = windowState.document {
            DocumentEditorView(document: document)
        } else if model.sources.isEmpty {
            ContentUnavailableView {
                Label("No folders yet", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a folder of Markdown files, or open a single file. Folders stay in the sidebar until you remove them.")
            } actions: {
                Button("Add Folder…") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .tint(.sage)
                Button("Open File…") { model.chooseFile() }
            }
            .background(Color.paper)
        } else {
            ContentUnavailableView {
                Label("No file selected", systemImage: "doc.text")
            } description: {
                Text("Choose a Markdown file from the sidebar.")
            }
            .background(Color.paper)
        }
    }
}

/// Editor + optional preview, split by a draggable divider that stores its
/// position as a fraction of the container width.
private struct EditorPreviewSplit: View {
    @ObservedObject var document: DocumentModel
    let fontSize: Double
    let lineSpacing: Double
    let isEditable: Bool
    let showPreview: Bool

    @AppStorage("previewFraction") private var previewFraction = 0.45
    @AppStorage("focusMode") private var focusMode = false
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var dragStartFraction: Double?
    @StateObject private var scrollSync = ScrollSync()

    private static let minEditor: CGFloat = 220
    private static let minPreview: CGFloat = 180

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let editorWidth = showPreview
                ? min(max(width * (1 - previewFraction), Self.minEditor), max(width - Self.minPreview, Self.minEditor))
                : width

            HStack(spacing: 0) {
                MarkdownEditor(text: $document.text, fontSize: fontSize,
                               lineSpacing: lineSpacing, focusMode: focusMode,
                               isEditable: isEditable,
                               scrollSync: showPreview ? scrollSync : nil)
                    .id(document.id)
                    .frame(width: editorWidth)
                if showPreview {
                    splitHandle(containerWidth: width)
                    // No `.id(...)`: recreating the WebView per file switch
                    // reloads the ~1.7 MB font-embedded shell and blanks the
                    // pane; the coordinator swaps content in place instead.
                    MarkdownPreview(markdown: document.text, documentID: document.id,
                                    scrollSync: scrollSync)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func splitHandle(containerWidth: CGFloat) -> some View {
        Divider()
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        guard containerWidth > Self.minEditor + Self.minPreview else { return }
                        let base = dragStartFraction ?? previewFraction
                        dragStartFraction = base
                        // translation is physical; in RTL chrome the editor
                        // sits on the right, so dragging left grows it.
                        let physical = value.translation.width
                        let delta = layoutDirection == .rightToLeft ? physical : -physical
                        let proposed = base + delta / containerWidth
                        let lower = Double(Self.minPreview / containerWidth)
                        let upper = Double(1 - Self.minEditor / containerWidth)
                        previewFraction = min(max(proposed, lower), upper)
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
    }
}

/// Dev/testing flags (no Accessibility needed): `-windowSize 800x600`,
/// `-devFullScreen`, `-devSecondWindow` (opens a second window selecting the
/// last file), `-devSecondTab` (same but merged as a native tab),
/// `-devCycleFiles N` (steps the selection through the workspace every N
/// seconds — exercises the editor/preview swap without clicking).
@MainActor
private func applyDevWindowFlags(model: AppModel, windowState: WindowState,
                                 openWindow: @escaping () -> Void,
                                 openSettings: @escaping () -> Void) {
    let args = CommandLine.arguments
    let index = DevWindowCounter.next()

    if let flagIndex = args.firstIndex(of: "-windowSize"), flagIndex + 1 < args.count, index == 0 {
        let parts = args[flagIndex + 1].split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.windows.first { $0.canBecomeKey }?
                    .setContentSize(NSSize(width: parts[0], height: parts[1]))
            }
        }
    }
    if args.contains("-devFullScreen"), index == 0 {
        enterFullScreenWhenReady(attemptsLeft: 20)
    }
    if args.contains("-devShowSettings"), index == 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
    if let flagIndex = args.firstIndex(of: "-devCycleFiles"), flagIndex + 1 < args.count,
       let period = Double(args[flagIndex + 1]), index == 0 {
        cycleFiles(model: model, windowState: windowState, period: period, step: 0)
    }
    if index == 0 {
        if args.contains("-devSecondWindow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openWindow() }
        } else if args.contains("-devSecondTab") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                WindowTabbing.openAsTab(openWindow)
            }
        }
    } else if args.contains("-devSecondWindow") || args.contains("-devSecondTab") {
        // Demonstrate per-window independence: the extra window shows the
        // last file instead of the default.
        windowState.selection = visibleFiles(model).last
    }
}

/// Files currently readable from the loaded part of the tree — dev flags only.
@MainActor
private func visibleFiles(_ model: AppModel) -> [DocumentID] {
    model.sources.flatMap { source -> [DocumentID] in
        let root = DocumentID(sourceID: source.id, path: "")
        model.loadChildren(of: root)
        return (model.children(of: root) ?? []).filter { !$0.isDirectory }.map(\.id)
    }
}

@MainActor
private func cycleFiles(model: AppModel, windowState: WindowState,
                        period: Double, step: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + period) {
        let files = visibleFiles(model)
        guard !files.isEmpty else {
            cycleFiles(model: model, windowState: windowState, period: period, step: step)
            return
        }
        windowState.selection = files[step % files.count]
        cycleFiles(model: model, windowState: windowState, period: period, step: step + 1)
    }
}

@MainActor
private enum DevWindowCounter {
    private static var count = 0
    static func next() -> Int {
        defer { count += 1 }
        return count
    }
}

@MainActor
private func enterFullScreenWhenReady(attemptsLeft: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let window = NSApp.windows.first(where: { $0.canBecomeKey && $0.isVisible }) {
            window.toggleFullScreen(nil)
        } else if attemptsLeft > 0 {
            enterFullScreenWhenReady(attemptsLeft: attemptsLeft - 1)
        }
    }
}

/// Waiting for, or failing to get, a document that isn't on this Mac.
private struct DocumentPlaceholder: View {
    let message: Text
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            message
                .font(.custom("IBMPlexSans", size: 13))
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try Again", action: retry)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    }
}

/// Says plainly that edits won't be saved, rather than letting someone type
/// into a document that silently discards their work.
private struct ReadOnlyBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye")
                .foregroundStyle(Color.slate)
                .accessibilityHidden(true)
            Text("Read-only. Saving to this source isn't supported yet.")
            Spacer(minLength: 0)
        }
        .font(.custom("IBMPlexSans", size: 12))
        .foregroundStyle(Color.slate)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.sand)
    }
}

/// Shown when a file changed on disk while the editor held unsaved edits.
/// Deliberately a banner rather than an alert: autosave is already paused, so
/// nothing is at risk while the user finishes a thought, and a modal here
/// would interrupt typing to ask a question they can answer at leisure.
private struct ConflictBanner: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.gold)
                .accessibilityHidden(true)   // the sentence beside it says this
            Text("This file changed on disk. Autosave is paused.")
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Keep My Version") { document.resolveKeepingMine() }
            Button("Reload from Disk") { document.resolveUsingDisk() }
        }
        .font(.custom("IBMPlexSans", size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.sand)
    }
}

/// Invisible view that reports when its window becomes key, so AppModel knows
/// which window's state should receive externally opened files (Finder
/// "Open With", Dock drops). SwiftUI offers no direct NSWindow handle; this
/// is the standard bridge.
private struct KeyWindowTracker: NSViewRepresentable {
    let onBecomeKey: () -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onBecomeKey = onBecomeKey
    }

    final class TrackerView: NSView {
        var onBecomeKey: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            if window.isKeyWindow { onBecomeKey?() }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBecomeKey?() }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

struct DocumentEditorView: View {
    @ObservedObject var document: DocumentModel
    @EnvironmentObject private var windowState: WindowState
    @AppStorage("editorFontSize") private var fontSize = 16.0
    @AppStorage("editorLineSpacing") private var lineSpacing = 1.4
    @AppStorage("showFormatBar") private var showFormatBar = true

    var body: some View {
        VStack(spacing: 0) {
            if showFormatBar {
                FormatBarView()
                Divider()
            }
            if document.hasConflict {
                ConflictBanner(document: document)
                Divider()
            }
            if document.isReadOnly, document.loadState == .ready {
                ReadOnlyBanner()
                Divider()
            }
            // Not HSplitView: it keeps the divider at an absolute offset, so
            // shrinking the window clips panes/crushes the sidebar and
            // entering full screen dumps all new width into one pane. This
            // split stores the *fraction* instead, which scales with any
            // resize and mirrors correctly in RTL chrome.
            switch document.loadState {
            case .loading:
                DocumentPlaceholder(message: Text("Loading…"), retry: nil)
            case .failed(let reason):
                DocumentPlaceholder(message: Text(verbatim: reason)) {
                    document.retryLoad()
                }
            case .ready:
                EditorPreviewSplit(document: document, fontSize: fontSize,
                                   lineSpacing: lineSpacing,
                                   isEditable: !document.isReadOnly,
                                   showPreview: windowState.showPreview)
            }
            Divider()
            StatusBarView(text: document.text, errorMessage: document.lastError,
                          isSaving: document.isSaving,
                          showPreview: $windowState.showPreview)
        }
        .background(Color.paper)
    }
}
