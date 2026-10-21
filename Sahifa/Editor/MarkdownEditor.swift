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
    var isEditable: Bool = true
    /// False for CSV and TSV: no Markdown styling, and no reading measure —
    /// a row of data isn't prose, and wrapping it at 65 characters only
    /// scatters it.
    var isMarkdown: Bool = true
    var scrollSync: ScrollSync? = nil

    /// Comfortable measure for the text column: ~34em of the base size, which
    /// is around 65 Latin characters — the span the eye tracks without losing
    /// its place. Scales with the font-size setting, and matches the 34rem
    /// text column the preview and export CSS use, so a line wraps at roughly
    /// the same word in both panes.
    static let measureEm: CGFloat = 34

    static func measureCap(forFontSize size: CGFloat) -> CGFloat {
        (measureEm * size).rounded()
    }

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
        textView.textContainerInset = NSSize(width: BidiTextView.minimumSideInset, height: 24)
        textView.maxTextWidth = isMarkdown ? Self.measureCap(forFontSize: CGFloat(fontSize)) : 0

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
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

        coordinator.styler.theme = EditorTheme(fontSize: CGFloat(fontSize),
                                               lineHeightMultiple: CGFloat(lineSpacing))
        coordinator.styler.parsesMarkdown = isMarkdown
        coordinator.attach(textView, contentStorage: contentStorage, layoutManager: layoutManager)
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

        // An undo the storage holds but the document doesn't yet must go out
        // before the document's text is compared with the editor's, or it
        // would be mistaken for an external change and written back over.
        coordinator.syncFromStorage()
        if coordinator.adoptExternalText(text) {
            needsRestyle = true
        }

        // A document can become editable while open (converted to UTF-8), or
        // stop being so (reloaded as something it can't save faithfully).
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if coordinator.styler.parsesMarkdown != isMarkdown {
            coordinator.styler.parsesMarkdown = isMarkdown
            needsRestyle = true
        }

        textView.maxTextWidth = isMarkdown ? Self.measureCap(forFontSize: CGFloat(fontSize)) : 0

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

        /// Takes charge of a text view: its delegate, and the storage edits
        /// behind it.
        func attach(_ textView: BidiTextView, contentStorage: NSTextContentStorage,
                    layoutManager: NSTextLayoutManager) {
            textView.delegate = self
            self.textView = textView
            self.contentStorage = contentStorage
            self.layoutManager = layoutManager
            guard let storage = textView.textStorage else { return }
            styler.observeEdits(of: storage)
            // Undo and redo rewrite the storage without textDidChange under
            // TextKit 2, so the storage itself is watched: the document, the
            // styling and the bars have to follow those edits too, or the
            // next SwiftUI update put the pre-undo text back over them.
            NotificationCenter.default.addObserver(
                self, selector: #selector(storageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: storage)
        }

        private var syncScheduled = false

        @objc private func storageDidProcessEditing(_ notification: Notification) {
            guard let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters), !syncScheduled else { return }
            // Not now: the storage is still inside its edit, and styling it
            // from here isn't allowed. Typing has already synced by the time
            // this runs and costs one comparison; undo hasn't.
            syncScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.syncScheduled = false
                self?.syncFromStorage()
            }
        }

        /// Brings the document, the focus paragraph and the styling up to
        /// date with whatever the storage holds now.
        func syncFromStorage() {
            guard let textView, !textView.hasMarkedText() else { return }
            let current = textView.string
            let changed = !(current as NSString).isEqual(to: parent.text)
            guard changed || styler.hasPendingEdit else { return }
            if changed { parent.text = current }
            _ = updateFocusParagraph()
            restyle(onlyEdited: true)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        var focusMode = false

        @objc func editorBoundsDidChange(_ notification: Notification) {
            scrollSync?.editorDidScroll()
        }

        func textDidChange(_ notification: Notification) {
            syncFromStorage()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if updateFocusParagraph() {
                restyle(onlyEdited: true)
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

        /// Puts the document's text into the editor when it changed somewhere
        /// else: another window on the same file, a reload from disk. Returns
        /// whether anything changed.
        ///
        /// Compared as UTF-16, not as Swift Strings: those count canonically
        /// equivalent text as equal ("é" and "e" + U+0301), which would leave
        /// the editor showing one form while the document holds the other.
        /// Never in the middle of a composition: the model doesn't have the
        /// marked text yet, and replacing it would throw the input away.
        func adoptExternalText(_ text: String) -> Bool {
            guard let textView, !textView.hasMarkedText(),
                  !(textView.string as NSString).isEqual(to: text) else { return false }
            let selection = textView.selectedRange()
            textView.string = text
            // Undo steps recorded against the old text point at ranges that
            // no longer exist; replaying one raised an out-of-bounds exception
            // that took the app down.
            textView.undoManager?.removeAllActions()
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            return true
        }

        /// `onlyEdited` restyles just what the user's own edit changed, which
        /// keeps typing fast in a long document; text set from outside needs
        /// the full pass.
        func restyle(onlyEdited: Bool = false) {
            guard let textView, let storage = textView.textStorage else { return }
            if onlyEdited {
                styler.restyleEdited(storage)
            } else {
                styler.restyle(storage)
            }
            textView.refreshDirectionBars()
        }
    }
}
