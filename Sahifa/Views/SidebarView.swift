import SwiftUI

/// Workspace sidebar. CHROME DIRECTION RULE: rows follow the app UI
/// language's layout direction, never the filename's script. An Arabic-named
/// file in English UI keeps its icon on the LEFT and its text leading-aligned
/// (".md" trailing) — only the Arabic glyphs themselves shape RTL inline.
/// This is enforced by (a) the inherited app layoutDirection ordering the
/// HStack, and (b) a directional mark pinning each label's base direction to
/// the chrome direction (see `chromeLabel`).
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowState: WindowState

    var body: some View {
        Group {
            if model.workspaceURL != nil {
                List(selection: $windowState.selectedFile) {
                    Section {
                        ForEach(model.files, id: \.self) { url in
                            FileRow(url: url)
                                .tag(url)
                        }
                    } header: {
                        WorkspaceHeader(name: model.workspaceURL?.lastPathComponent ?? "")
                    }
                }
                .listStyle(.sidebar)
                // In full screen the title bar collapses and the list would
                // sit flush against the panel's top edge.
                .padding(.top, 6)
            } else {
                VStack(spacing: 12) {
                    Text("No folder open")
                        .foregroundStyle(Color.slate)
                    Button("Open Folder…") { model.chooseFolder() }
                    Button("Open File…") { model.chooseFile() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.sand)
        // Sidebar footer duplicates the window-toolbar actions: under forced
        // RTL chrome (uiLanguage = "ar") NSToolbar pushes the items into its
        // overflow menu, so keep an always-visible home for them here.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 16) {
                Button {
                    model.chooseFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help(Text("Open Folder…"))
                Button {
                    model.chooseFile()
                } label: {
                    Image(systemName: "doc")
                }
                .help(Text("Open File…"))
                Button {
                    if let url = model.newFile() { windowState.selectedFile = url }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(model.workspaceURL == nil)
                .help(Text("New File"))
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.slate)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.sand)
        }
    }
}

private struct WorkspaceHeader: View {
    let name: String
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Text(verbatim: chromeLabel(name, layoutDirection))
            .font(.custom("IBMPlexSans-SmBld", size: 11))
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FileRow: View {
    let url: URL
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .foregroundStyle(Color.slate)
                .imageScale(.small)
            Text(verbatim: chromeLabel(url.lastPathComponent, layoutDirection))
                .font(.custom("IBMPlexSans", size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Pins a label's rendered base direction to the app chrome direction by
/// prefixing an LRM/RLM strong mark — the equivalent of NOT using dir="auto"
/// on chrome. Filenames therefore never flip the row, whatever script they
/// start with.
private func chromeLabel(_ text: String, _ direction: LayoutDirection) -> String {
    (direction == .rightToLeft ? "\u{200F}" : "\u{200E}") + text
}
