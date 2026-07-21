import SwiftUI

/// A row of tabs, one per open document, above the editor. Opening a file adds
/// a tab and switching between them is instant. Two gestures beyond a click:
/// the + (and ⌘T) add a blank tab, and dragging a tab down out of the bar
/// detaches it into its own window — the instinctive "pull a tab off" gesture.
///
/// CHROME DIRECTION RULE (same as the sidebar): tabs follow the app UI
/// language's layout direction, not the filename's script. Enforced by the
/// inherited layoutDirection ordering the HStack plus a directional mark
/// pinning each label (see `chromeLabel`).
struct TabBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowState: WindowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(windowState.openTabs, id: \.self) { id in
                        TabButton(
                            title: title(for: id),
                            isActive: windowState.selection == id,
                            select: { windowState.selection = id },
                            close: { windowState.closeTab(id) },
                            detach: id.isBlankTab ? nil : { detach(id) }
                        )
                        .id(id)
                        Divider().frame(height: 16)
                    }
                    // A fresh blank tab, like a browser's +.
                    Button {
                        windowState.newBlankTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.slate)
                            .frame(width: 34, height: 33)
                    }
                    .buttonStyle(.plain)
                    .help(Text("New Tab"))
                    .accessibilityLabel(Text("New Tab"))
                    .pointerCursor(.pointingHand)
                    Spacer(minLength: 0)
                }
            }
            .background(Color.sand)
            .onChange(of: windowState.selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
    }

    private func title(for id: DocumentID) -> Text {
        id.isBlankTab
            ? Text("New Tab").italic()
            : Text(verbatim: chromeLabel(id.name, layoutDirection))
    }

    /// Pulls a tab out into its own window: stage the file so the new window
    /// opens on it, open the window, then drop the tab here.
    private func detach(_ id: DocumentID) {
        model.stagePendingSelection(id)
        openWindow(id: "main")
        windowState.closeTab(id)
    }
}

/// One tab. The active tab is lifted onto the editor's paper colour with a sage
/// underline; the close control is quiet until the tab is active or hovered.
/// A downward drag past the bar detaches it into a window (`detach`).
private struct TabButton: View {
    let title: Text
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    /// nil for a blank tab — an empty tab has no file to carry into a window.
    let detach: (() -> Void)?
    @State private var hovering = false
    @State private var closeHovering = false
    @GestureState private var dragOffset: CGSize = .zero

    private static let detachThreshold: CGFloat = 44

    var body: some View {
        HStack(spacing: 6) {
            title
                .font(.custom("IBMPlexSans", size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? Color.ink : Color.slate)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.slate)
                    .frame(width: 15, height: 15)
                    .background(closeHovering ? Color.slate.opacity(0.18) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || hovering ? 1 : 0)
            .onHover { closeHovering = $0 }
            .help(Text("Close Tab"))
            .accessibilityLabel(Text("Close Tab"))
            .pointerCursor(.pointingHand)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 200, alignment: .leading)
        .background(isActive ? Color.paper : Color.sand)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.sage)
                .frame(height: 2)
                .opacity(isActive ? 1 : 0)
        }
        .contentShape(Rectangle())
        .offset(dragOffset)
        .zIndex(dragOffset == .zero ? 0 : 1)
        .onTapGesture(perform: select)
        .gesture(
            DragGesture(minimumDistance: 12)
                .updating($dragOffset) { value, state, _ in
                    // Only file tabs lift and detach; a blank tab stays put.
                    if detach != nil { state = value.translation }
                }
                .onEnded { value in
                    // Pulled down out of the bar → detach into a window.
                    if let detach, value.translation.height > Self.detachThreshold {
                        detach()
                    }
                }
        )
        .onHover { hovering = $0 }
        .pointerCursor(.pointingHand)
    }
}
