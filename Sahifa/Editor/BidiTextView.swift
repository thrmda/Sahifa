import AppKit

/// TextKit 2 text view for bidirectional Markdown source. The system handles
/// inline bidi runs, caret movement and selection; this subclass only adds
/// the per-paragraph direction affordance: a thin bar in the margin at each
/// paragraph's leading edge — Ink on the left for LTR paragraphs, Sage on
/// the right for RTL paragraphs (echoing the app icon's seam).
///
/// The bars live in an overlay subview rather than in `draw(_:)`: with
/// TextKit 2, NSTextView renders text through private viewport subviews and
/// the text view's own `draw(_:)` is not part of the drawing path.
final class BidiTextView: NSTextView {

    private let barsOverlay = DirectionBarsOverlay()

    /// Widest the text column is allowed to get, in points. Beyond this the
    /// side insets grow instead, centring the column — a line that runs the
    /// full width of a 27-inch pane is unreadable. Set by MarkdownEditor from
    /// the current base font size; 0 means "no cap" (behave as before).
    var maxTextWidth: CGFloat = 0 {
        didSet { if maxTextWidth != oldValue { updateTextInsets() } }
    }

    /// Inset used when the pane is narrower than the cap — the original
    /// behaviour, and the floor for the centring inset.
    static let minimumSideInset: CGFloat = 28

    /// The inset is recomputed here rather than in `layout()`: changing it is
    /// itself a layout-affecting change, and doing that inside the layout pass
    /// leaves TextKit 2's viewport subviews without their text — the document
    /// lays out and the direction bars draw, but not a glyph is rendered.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextInsets()
    }

    override func layout() {
        super.layout()
        if barsOverlay.superview !== self {
            barsOverlay.textView = self
            addSubview(barsOverlay)
        }
        if barsOverlay.frame != bounds {
            barsOverlay.frame = bounds
        }
    }

    /// Grows the horizontal inset so the text column stays centred at its
    /// capped width. The container tracks the view width, so widening the
    /// inset is what narrows the column — and it keeps the caret, selection
    /// and find-bar geometry consistent, which setting an explicit container
    /// size would not.
    private func updateTextInsets() {
        let side: CGFloat
        if maxTextWidth > 0, bounds.width - 2 * Self.minimumSideInset > maxTextWidth {
            side = ((bounds.width - maxTextWidth) / 2).rounded(.down)
        } else {
            side = Self.minimumSideInset
        }
        guard abs(textContainerInset.width - side) > 0.5 else { return }
        textContainerInset = NSSize(width: side, height: textContainerInset.height)
        refreshDirectionBars()
    }

    func refreshDirectionBars() {
        barsOverlay.needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        refreshDirectionBars()
    }

    // MARK: File drops

    /// NSTextView accepts file drags on its own and inserts the path as text,
    /// which would swallow the window's file drop before SwiftUI's onDrop ever
    /// sees it. Markdown files and folders are opened instead; anything else
    /// (plain text drags, drags within the document) falls through to super.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        openableURLs(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        openableURLs(in: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = openableURLs(in: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        MainActor.assumeIsolated { AppModel.shared.openExternal(urls) }
        return true
    }

    private func openableURLs(in sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: options) as? [URL] ?? []
        return urls.filter { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? url.hasDirectoryPath
            return isDirectory
                || AppModel.isOpenable(url)
        }
    }
}

/// Transparent, non-interactive margin layer that draws the direction bars.
private final class DirectionBarsOverlay: NSView {

    weak var textView: BidiTextView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let storage = textView.textStorage
        else { return }

        let origin = textView.textContainerOrigin
        let documentStart = contentManager.documentRange.location

        layoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > dirtyRect.maxY { return false }
            if frame.maxY < dirtyRect.minY { return true }

            guard let elementRange = fragment.textElement?.elementRange else { return true }
            let offset = contentManager.offset(from: documentStart, to: elementRange.location)
            let length = contentManager.offset(from: elementRange.location, to: elementRange.endLocation)
            guard offset >= 0, length > 0, offset < storage.length else { return true }

            let paragraph = (storage.string as NSString)
                .substring(with: NSRange(location: offset, length: min(length, storage.length - offset)))
            guard !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }

            let isRTL = (storage.attribute(.sahifaDirection, at: offset, effectiveRange: nil) as? Int) == 1

            // Positioned off the inset, not off the pane edge, so the bars
            // stay pinned to the text column once it is capped and centred:
            // the container spans [inset, width - inset] by construction.
            let barWidth: CGFloat = 3
            let x: CGFloat = isRTL
                ? self.bounds.width - textView.textContainerInset.width + 9
                : textView.textContainerInset.width - 9 - barWidth
            let barRect = NSRect(x: x,
                                 y: frame.minY + 3,
                                 width: barWidth,
                                 height: max(4, frame.height - 8))
            let color = (isRTL ? Brand.sage : Brand.ink).withAlphaComponent(0.45)
            color.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
    }
}
