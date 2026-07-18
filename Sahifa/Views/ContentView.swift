import SwiftUI

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
        .onAppear {
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
                    Label("Open Folder…", systemImage: "folder")
                }
                .help(Text("Open Folder…"))
                Button {
                    model.chooseFile()
                } label: {
                    Label("Open File…", systemImage: "doc")
                }
                .help(Text("Open File…"))
                Button {
                    if let url = model.newFile() { windowState.selectedFile = url }
                } label: {
                    Label("New File", systemImage: "square.and.pencil")
                }
                .disabled(model.workspaceURL == nil)
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
        } else if model.workspaceURL == nil {
            ContentUnavailableView {
                Label("No folder open", systemImage: "folder")
            } description: {
                Text("Open a folder or a Markdown file to begin.")
            } actions: {
                Button("Open Folder…") { model.chooseFolder() }
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
                               scrollSync: showPreview ? scrollSync : nil)
                    .id(document.url)
                    .frame(width: editorWidth)
                if showPreview {
                    splitHandle(containerWidth: width)
                    MarkdownPreview(markdown: document.text, scrollSync: scrollSync)
                        .id(document.url)
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
/// last file), `-devSecondTab` (same but merged as a native tab).
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
        windowState.selectedFile = model.files.last
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
            // Not HSplitView: it keeps the divider at an absolute offset, so
            // shrinking the window clips panes/crushes the sidebar and
            // entering full screen dumps all new width into one pane. This
            // split stores the *fraction* instead, which scales with any
            // resize and mirrors correctly in RTL chrome.
            EditorPreviewSplit(document: document, fontSize: fontSize,
                               lineSpacing: lineSpacing, showPreview: windowState.showPreview)
            Divider()
            StatusBarView(text: document.text, errorMessage: document.lastError,
                          showPreview: $windowState.showPreview)
        }
        .background(Color.paper)
    }
}
