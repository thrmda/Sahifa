import SwiftUI
import AppKit

/// NSViewRepresentable wrapping BidiTextView (NSTextView on TextKit 2).
/// SwiftUI's TextEditor is deliberately not used — the system text engine's
/// bidi and Arabic shaping only shine through a real NSTextView.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var lineSpacing: Double
    var focusMode: Bool = false
    var scrollSync: ScrollSync? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        // Explicit TextKit 2 stack. Never touch `layoutManager`, which would
        // silently downgrade the view to TextKit 1.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = BidiTextView(frame: NSRect.zero, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.textContainerInset = NSSize(width: 28, height: 24)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.drawsBackground = true
        textView.backgroundColor = Brand.paper
        textView.insertionPointColor = Brand.sage
        textView.selectedTextAttributes = [
            NSAttributedString.Key.backgroundColor: Brand.sage.withAlphaComponent(0.25),
        ]

        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.contentStorage = contentStorage
        coordinator.layoutManager = layoutManager
        coordinator.styler.theme = EditorTheme(fontSize: CGFloat(fontSize),
                                               lineHeightMultiple: CGFloat(lineSpacing))
        textView.typingAttributes = coordinator.styler.baseAttributes()

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Brand.paper

        // Report scrolls to the sync so the preview can follow.
        coordinator.scrollSync = scrollSync
        scrollSync?.editorScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.editorBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        textView.string = text
        // setString leaves the caret at the end; open at the top instead
        // (this is also what focus mode highlights first).
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.restyle()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.scrollSync = scrollSync
        scrollSync?.editorScrollView = nsView
        guard let textView = coordinator.textView else { return }

        var needsRestyle = false

        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            needsRestyle = true
        }

        let theme = EditorTheme(fontSize: CGFloat(fontSize), lineHeightMultiple: CGFloat(lineSpacing))
        if coordinator.styler.theme != theme {
            coordinator.styler.theme = theme
            textView.typingAttributes = coordinator.styler.baseAttributes()
            needsRestyle = true
        }

        if coordinator.focusMode != focusMode {
            coordinator.focusMode = focusMode
            _ = coordinator.updateFocusParagraph()
            needsRestyle = true
        }

        if needsRestyle {
            coordinator.restyle()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        let styler = MarkdownStyler()
        weak var textView: BidiTextView?
        // TextKit 2 objects are not retained by the text view alone.
        var contentStorage: NSTextContentStorage?
        var layoutManager: NSTextLayoutManager?
        var scrollSync: ScrollSync?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        var focusMode = false

        @objc func editorBoundsDidChange(_ notification: Notification) {
            scrollSync?.editorDidScroll()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, !textView.hasMarkedText() else { return }
            parent.text = textView.string
            _ = updateFocusParagraph()
            restyle()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if updateFocusParagraph() {
                restyle()
            }
        }

        /// Returns true when the focus paragraph actually changed.
        func updateFocusParagraph() -> Bool {
            guard let textView else { return false }
            let paragraph: NSRange? = focusMode
                ? (textView.string as NSString).paragraphRange(for: textView.selectedRange())
                : nil
            guard styler.focusParagraph != paragraph else { return false }
            styler.focusParagraph = paragraph
            return true
        }

        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            styler.restyle(storage)
            textView.refreshDirectionBars()
        }
    }
}
