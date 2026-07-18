import AppKit
import WebKit

/// Keeps the editor and the live preview scrolled to the same *fractional*
/// position (offset ÷ scrollable height). Proportional sync is simple and
/// robust across the two very different layouts — the alternative, mapping
/// source lines to rendered elements, is far more fragile with bidi/markdown.
///
/// Both sides register their view here; whichever the user scrolls drives the
/// other. Programmatic scrolls are guarded on each side (a Swift flag plus a
/// matching JS flag in the preview shell) so the two never ping-pong, and an
/// epsilon check drops the sub-pixel echoes that survive rounding.
@MainActor
final class ScrollSync: ObservableObject {
    weak var editorScrollView: NSScrollView?
    weak var previewWebView: WKWebView?

    private var suppressEditor = false
    private var suppressPreview = false
    private static let epsilon: CGFloat = 0.002

    /// Editor moved → drive the preview.
    func editorDidScroll() {
        guard !suppressEditor, let fraction = editorFraction() else { return }
        scrollPreview(to: fraction)
    }

    /// Preview moved (reported from JS) → drive the editor.
    func previewDidScroll(_ fraction: CGFloat) {
        guard !suppressPreview else { return }
        scrollEditor(to: fraction)
    }

    private func editorFraction() -> CGFloat? {
        guard let sv = editorScrollView, let doc = sv.documentView else { return nil }
        let maxOffset = max(0, doc.frame.height - sv.contentView.bounds.height)
        guard maxOffset > 0 else { return 0 }
        return sv.contentView.bounds.origin.y / maxOffset
    }

    private func scrollEditor(to fraction: CGFloat) {
        guard let sv = editorScrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let maxOffset = max(0, doc.frame.height - clip.bounds.height)
        let current = maxOffset > 0 ? clip.bounds.origin.y / maxOffset : 0
        guard abs(current - fraction) > Self.epsilon else { return }
        suppressEditor = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: maxOffset * fraction))
        sv.reflectScrolledClipView(clip)
        suppressEditor = false   // boundsDidChange fires synchronously above
    }

    private func scrollPreview(to fraction: CGFloat) {
        guard let web = previewWebView else { return }
        suppressPreview = true
        web.evaluateJavaScript("sahifaScrollTo(\(fraction))") { [weak self] _, _ in
            self?.suppressPreview = false
        }
    }
}
