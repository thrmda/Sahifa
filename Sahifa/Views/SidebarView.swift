import SwiftUI

/// Sources and their contents. Each added folder is a root that expands into
/// its own tree; children are read when a folder is opened rather than up
/// front, because walking a real notes folder eagerly is wasteful and no later
/// remote source could do it at all.
///
/// Disclosure is a real `DisclosureGroup` rather than a hand-rolled chevron
/// plus tap gesture: taps on a row inside a List are unreliable to intercept,
/// and the system control brings the correct triangle, RTL mirroring and
/// keyboard behaviour for free.
///
/// CHROME DIRECTION RULE: rows follow the app UI language's layout direction,
/// never the filename's script. An Arabic-named file in English UI keeps its
/// icon on the LEFT and its text leading-aligned (".md" trailing) — only the
/// Arabic glyphs themselves shape RTL inline. This is enforced by (a) the
/// inherited app layoutDirection ordering the HStack, and (b) a directional
/// mark pinning each label's base direction to the chrome direction (see
/// `chromeLabel`).
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowState: WindowState

    var body: some View {
        Group {
            if model.sources.isEmpty {
                emptyState
            } else {
                // A plain click shows the file in the CURRENT tab (browsing
                // reuses one tab); "Open in New Tab" is the explicit way to add
                // one. So the List's selection is a computed binding that routes
                // clicks through showInCurrentTab rather than setting selection
                // directly.
                List(selection: Binding(
                    get: { windowState.selection },
                    set: { newValue in
                        if let newValue { windowState.showInCurrentTab(newValue) }
                        else { windowState.selection = nil }
                    }
                )) {
                    ForEach(model.sources) { source in
                        SourceDisclosure(source: source)
                    }
                    // Drag a root up or down to reorder the sources; the order
                    // persists. Only the top-level roots move — files inside a
                    // folder aren't reorderable (their order is the folder's).
                    .onMove { model.moveSources(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.sidebar)
                // In full screen the title bar collapses and the list would
                // sit flush against the panel's top edge.
                .padding(.top, 6)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sand)
        // Footer duplicates the window-toolbar actions: under forced RTL
        // chrome (uiLanguage = "ar") NSToolbar pushes the items into its
        // overflow menu, so keep an always-visible home for them here.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 16) {
                Button {
                    model.chooseFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help(Text("Add Folder…"))
                .accessibilityLabel(Text("Add Folder…"))
                .pointerCursor(.pointingHand)
                Button {
                    model.chooseFile()
                } label: {
                    Image(systemName: "doc")
                }
                .help(Text("Open File…"))
                .accessibilityLabel(Text("Open File…"))
                .pointerCursor(.pointingHand)
                Button {
                    Task {
                        if let id = await model.newFile(in: windowState.newFileTarget) {
                            windowState.selection = id
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!model.canCreateFiles)
                .help(Text("New File"))
                .accessibilityLabel(Text("New File"))
                .pointerCursor(.pointingHand)
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.slate)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.sand)
        }
    }

    // Note: the footer buttons get the pointing hand individually below rather
    // than on the row, so the gaps between them keep the arrow.

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No folders yet")
                .foregroundStyle(Color.slate)
            Button("Add Folder…") { model.chooseFolder() }
            Button("Open File…") { model.chooseFile() }
            Button("Add GitHub Repository…") { RepositoryPrompt.show(model) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One source: a disclosure row that expands into the folder's tree.
private struct SourceDisclosure: View {
    let source: Source
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowState: WindowState
    @Environment(\.layoutDirection) private var layoutDirection

    private var root: DocumentID { DocumentID(sourceID: source.id, path: "") }

    /// The leading type badge for a source root. Fixed width so the names line
    /// up whichever icon a row carries. The GitHub mark is a bundled template
    /// vector (SF Symbols ships no brand logos); the others are SF Symbols.
    @ViewBuilder
    private var sourceIcon: some View {
        Group {
            switch source.kind {
            case .localFolder:
                Image(systemName: "folder")
                    .imageScale(.small)
                    .foregroundStyle(Color.slate)
                    .accessibilityLabel(Text("Local folder"))
            case .gitHub:
                Image("GitHubMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Color.slate)
                    .accessibilityLabel(Text("GitHub repository"))
            case .looseFiles:
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(Color.slate)
                    .accessibilityLabel(Text("Opened files"))
            }
        }
        .frame(width: 15)
    }

    var body: some View {
        DisclosureGroup(isExpanded: windowState.expansionBinding(for: root)) {
            NodeRows(parent: root)
        } label: {
            HStack(spacing: 6) {
                // Leading type icon so each root reads at a glance: a folder for
                // a local folder, the GitHub mark for a repo, stacked pages for
                // the loose "Opened Files".
                sourceIcon
                Text(verbatim: chromeLabel(source.name, layoutDirection))
                    .font(.custom("IBMPlexSans-SmBld", size: 11))
                    .foregroundStyle(Color.slate)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // Reserved status slot. Local folders only speak up when
                // they've gone missing; a remote source will use this for
                // syncing / offline / sign-in-needed without a relayout.
                switch source.status {
                case .ready:
                    EmptyView()
                case .missing:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Color.gold)
                        .help(Text("This folder is missing"))
                        .accessibilityLabel(Text("This folder is missing"))
                case .needsSignIn:
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .imageScale(.small)
                        .foregroundStyle(Color.gold)
                        .help(Text("Sign-in needed — reconnect in Settings"))
                        .accessibilityLabel(Text("Sign-in needed — reconnect in Settings"))
                }
            }
            .contextMenu {
                Button("Remove from Sidebar") { model.removeSource(source.id) }
                if let root = source.rootURL, source.kind == .localFolder {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }
                }
            }
        }
    }
}

/// The children of one directory. Directories nest another DisclosureGroup;
/// files are plain selectable rows.
private struct NodeRows: View {
    let parent: DocumentID
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowState: WindowState

    var body: some View {
        if let nodes = model.children(of: parent) {
            ForEach(nodes) { node in
                if node.isDirectory {
                    DisclosureGroup(isExpanded: windowState.expansionBinding(for: node.id)) {
                        NodeRows(parent: node.id)
                    } label: {
                        NodeLabel(node: node)
                    }
                } else {
                    NodeLabel(node: node).tag(node.id)
                }
            }
            if nodes.isEmpty {
                Text("Empty")
                    .font(.custom("IBMPlexSans", size: 12))
                    .foregroundStyle(Color.slate)
                    .selectionDisabled()
            }
        } else if let failure = model.directoryErrors[parent] {
            // A folder that can't be fetched says so and offers another go,
            // rather than sitting on a spinner that never resolves.
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: failure)
                    .foregroundStyle(Color.gold)
                    .lineLimit(3)
                Button("Try Again") { model.loadChildren(of: parent, force: true) }
                    .buttonStyle(.link)
            }
            .font(.custom("IBMPlexSans", size: 11))
            .selectionDisabled()
        } else {
            Text("Loading…")
                .font(.custom("IBMPlexSans", size: 12))
                .foregroundStyle(Color.slate)
                .selectionDisabled()
                .task { model.loadChildren(of: parent) }
        }
    }
}

private struct NodeLabel: View {
    let node: Node
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowState: WindowState
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var renameFieldFocused: Bool

    private var isLoose: Bool { node.id.sourceID == Source.looseFilesID }
    /// Reveal in Finder only means something for a file on this Mac.
    private var isLocal: Bool { model.source(node.id.sourceID)?.isLocal ?? false }
    /// Rename, delete and New File Here work wherever the source is writable —
    /// a local folder or a connected repository, but not loose files.
    private var canOrganise: Bool { model.canOrganise(node.id) }
    @State private var confirmingDelete = false
    private var isRenaming: Bool { windowState.renaming == node.id }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: node.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(Color.slate)
                .imageScale(.small)
                .accessibilityHidden(true)
            if isRenaming {
                // Inline, like Finder and Xcode — a sheet to rename one file
                // is heavier than the action deserves.
                TextField("", text: $windowState.renameText)
                    .textFieldStyle(.plain)
                    .font(.custom("IBMPlexSans", size: 13))
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { windowState.renaming = nil }
                    .onChange(of: renameFieldFocused) { _, focused in
                        // Clicking away commits, matching Finder.
                        if !focused && isRenaming { commitRename() }
                    }
                    .task { renameFieldFocused = true }
            } else {
                Text(verbatim: chromeLabel(node.name, layoutDirection))
                    .font(.custom("IBMPlexSans", size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            if !node.isDirectory {
                Button("Open in New Tab") { windowState.openInNewTab(node.id) }
                Divider()
            }
            if canOrganise {
                Button("Rename…") { beginRename() }
            }
            if isLocal {
                Button("Reveal in Finder") {
                    if let url = model.url(for: node.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            if node.isDirectory && canOrganise {
                Button("New File Here") {
                    Task {
                        if let id = await model.newFile(in: node.id) {
                            windowState.expanded.insert(node.id)
                            windowState.selection = id
                        }
                    }
                }
            }
            if isLoose {
                // Its folder isn't in the sidebar, so "remove" here means stop
                // listing it — deleting the file is the separate, louder verb.
                Button("Remove from Opened Files") {
                    model.removeFromOpenedFiles(node.id)
                }
            }
            if isLocal || canOrganise { Divider() }
            if canOrganise {
                Button(deleteTitle, role: .destructive) {
                    if model.deletionNeedsConfirmation(node.id) {
                        confirmingDelete = true
                    } else {
                        Task { await model.delete(node.id) }
                    }
                }
            }
        }
        // A repository delete is a commit, not the Trash, so it confirms first.
        .confirmationDialog(deletePrompt, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await model.delete(node.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var deleteTitle: LocalizedStringKey {
        model.deletionNeedsConfirmation(node.id) ? "Delete…" : "Move to Trash"
    }
    private var deletePrompt: Text {
        Text("Delete \(node.name) from the repository? This is a commit, not the Trash.")
    }

    private func beginRename() {
        windowState.renameText = node.name
        windowState.renaming = node.id
    }

    private func commitRename() {
        let newName = windowState.renameText
        windowState.renaming = nil
        guard newName != node.name else { return }
        Task {
            if let renamed = await model.rename(node.id, to: newName),
               windowState.selection == nil {
                windowState.selection = renamed
            }
        }
    }
}

/// Pins a label's rendered base direction to the app chrome direction by
/// prefixing an LRM/RLM strong mark — the equivalent of NOT using dir="auto"
/// on chrome. Filenames therefore never flip the row, whatever script they
/// start with.
func chromeLabel(_ text: String, _ direction: LayoutDirection) -> String {
    (direction == .rightToLeft ? "\u{200F}" : "\u{200E}") + text
}
