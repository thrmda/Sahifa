import SwiftUI
import AppKit

/// Sets the pointer over a region using AppKit cursor rects rather than
/// `NSCursor.push()/pop()`.
///
/// push/pop keeps a stack, and the balancing pop never fires if the view goes
/// away while hovered — hide the sidebar mid-hover and the resize cursor
/// sticks. A cursor rect is owned by the view: AppKit shows it on entry,
/// reverts on exit, and drops it when the view is removed, with nothing to
/// balance. During a live drag the rects are suspended, so callers that need
/// the cursor held through a drag set it themselves in the gesture.
private struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView { CursorView(cursor: cursor) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CursorView, view.cursor != cursor else { return }
        view.cursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var cursor: NSCursor

        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }
    }
}

extension View {
    /// Shows `cursor` while the pointer is over this view.
    func pointerCursor(_ cursor: NSCursor) -> some View {
        background(CursorArea(cursor: cursor))
    }
}
