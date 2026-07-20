import SwiftUI

/// Icon toolbar over the editor with one button per Markdown styling action —
/// the no-keyboard-shortcuts path. Lives in content (not the window toolbar)
/// so it survives narrow windows and mirrors correctly in RTL chrome.
struct FormatBarView: View {

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Heading 1") { sendToEditor(#selector(BidiTextView.sahifaHeading1(_:))) }
                Button("Heading 2") { sendToEditor(#selector(BidiTextView.sahifaHeading2(_:))) }
                Button("Heading 3") { sendToEditor(#selector(BidiTextView.sahifaHeading3(_:))) }
                Button("Heading 4") { sendToEditor(#selector(BidiTextView.sahifaHeading4(_:))) }
            } label: {
                // `number` (#) is script-neutral and is literally the Markdown
                // heading marker. Avoids the letterform symbols (textformat.size
                // → Aa/عأ) whose variant follows the process language, not the
                // in-app uiLanguage, and so mismatch the chrome when they differ.
                Image(systemName: "number")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Headings"))
            .accessibilityLabel(Text("Headings"))
            .pointerCursor(.pointingHand)

            barDivider

            iconButton("bold", "Bold", #selector(BidiTextView.sahifaToggleBold(_:)))
            iconButton("italic", "Italic", #selector(BidiTextView.sahifaToggleItalic(_:)))
            iconButton("strikethrough", "Strikethrough", #selector(BidiTextView.sahifaToggleStrikethrough(_:)))

            barDivider

            iconButton("list.bullet", "Bulleted List", #selector(BidiTextView.sahifaToggleBulletList(_:)))
            iconButton("list.number", "Numbered List", #selector(BidiTextView.sahifaToggleNumberedList(_:)))
            iconButton("text.quote", "Quote", #selector(BidiTextView.sahifaToggleQuote(_:)))

            barDivider

            iconButton("chevron.left.forwardslash.chevron.right", "Inline Code",
                       #selector(BidiTextView.sahifaToggleInlineCode(_:)))
            iconButton("curlybraces", "Code Block", #selector(BidiTextView.sahifaInsertCodeBlock(_:)))

            barDivider

            iconButton("link", "Link", #selector(BidiTextView.sahifaInsertLink(_:)))
            iconButton("photo", "Image", #selector(BidiTextView.sahifaInsertImage(_:)))
            iconButton("minus", "Horizontal Rule", #selector(BidiTextView.sahifaInsertHorizontalRule(_:)))
            iconButton("tablecells", "Table", #selector(BidiTextView.sahifaInsertTable(_:)))

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .foregroundStyle(Color.slate)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.sand)
    }

    private var barDivider: some View {
        Divider()
            .frame(height: 14)
            .padding(.horizontal, 3)
    }

    /// `.help` is a tooltip and a VoiceOver *hint*, not a name — without an
    /// explicit label these icon-only buttons fall back to whatever the SF
    /// Symbol happens to be called. The window toolbar already names its
    /// buttons via `Label`; this keeps the two consistent.
    private func iconButton(_ symbol: String, _ help: LocalizedStringKey,
                            _ selector: Selector) -> some View {
        Button {
            sendToEditor(selector)
        } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 18)
        }
        .help(Text(help))
        .accessibilityLabel(Text(help))
        .pointerCursor(.pointingHand)
    }
}

/// Routes a formatting action to the editor. First responder normally IS the
/// editor; if a bar click moved focus, fall back to finding the editor view
/// in the key window.
@MainActor
private func sendToEditor(_ selector: Selector) {
    if let responder = NSApp.keyWindow?.firstResponder, responder.responds(to: selector) {
        _ = responder.perform(selector, with: nil)
        return
    }
    if let content = NSApp.keyWindow?.contentView, let editor = findEditor(in: content) {
        _ = editor.perform(selector, with: nil)
        editor.window?.makeFirstResponder(editor)
    }
}

@MainActor
private func findEditor(in view: NSView) -> BidiTextView? {
    if let editor = view as? BidiTextView { return editor }
    for subview in view.subviews {
        if let editor = findEditor(in: subview) { return editor }
    }
    return nil
}
