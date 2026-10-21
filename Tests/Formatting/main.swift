import AppKit

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

/// A real BidiTextView in a real (offscreen) window: NSTextView takes its
/// undo manager from the window, so undo can't be exercised without one.
@MainActor
func makeEditor(_ text: String, select: NSRange) -> BidiTextView {
    let view = BidiTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.contentView = view
    view.allowsUndo = true
    view.string = text
    view.setSelectedRange(select)
    return view
}

/// Registers the bundled Plex faces from the built app. FontLibrary's own
/// loader reads Bundle.main, which for this CLI binary is not the app, so the
/// font-dependent checks would otherwise measure system fallbacks.
@discardableResult
func registerPlexFonts() -> Bool {
    let fonts = URL(fileURLWithPath: "build/DerivedData/Build/Products/Debug/Sahifa.app")
        .appendingPathComponent("Contents/Resources/fonts", isDirectory: true)
    guard let contents = try? FileManager.default.contentsOfDirectory(at: fonts,
                                                                     includingPropertiesForKeys: nil)
    else { return false }
    for url in contents where url.pathExtension.lowercased() == "otf" {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    return NSFont(name: "IBMPlexSansArabic-Regular", size: 12) != nil
}

@MainActor
func run() {
    // MARK: Inline delimiters

    do {
        let e = makeEditor("hello world", select: NSRange(location: 0, length: 5))
        e.sahifaToggleBold(nil)
        check("bold wraps the selection", e.string == "**hello** world", e.string)
        e.sahifaToggleBold(nil)
        check("bold again unwraps it", e.string == "hello world", e.string)
    }

    do {
        let e = makeEditor("hello", select: NSRange(location: 5, length: 0))
        e.sahifaToggleItalic(nil)
        check("italic with no selection inserts a pair", e.string == "hello**", e.string)
        check("…and puts the caret between them",
              e.selectedRange().location == 6, "caret at \(e.selectedRange().location)")
    }

    do {
        let e = makeEditor("مرحبا بالعالم", select: NSRange(location: 0, length: 5))
        e.sahifaToggleBold(nil)
        check("bold wraps an Arabic selection", e.string == "**مرحبا** بالعالم", e.string)
        e.sahifaToggleBold(nil)
        check("…and unwraps it", e.string == "مرحبا بالعالم", e.string)
    }

    // MARK: Headings

    do {
        let e = makeEditor("Title", select: NSRange(location: 0, length: 0))
        e.sahifaHeading1(nil)
        check("heading 1 prefixes the line", e.string == "# Title", e.string)
        e.sahifaHeading2(nil)
        check("heading 2 replaces it rather than stacking", e.string == "## Title", e.string)
        e.sahifaHeading2(nil)
        check("the same heading toggles off", e.string == "Title", e.string)
    }

    // MARK: Lists

    do {
        let e = makeEditor("one\ntwo", select: NSRange(location: 0, length: 7))
        e.sahifaToggleBulletList(nil)
        check("bullet list marks every selected line", e.string == "- one\n- two", e.string)
        e.sahifaToggleNumberedList(nil)
        check("numbered list converts from bullets", e.string == "1. one\n2. two", e.string)
        e.sahifaToggleNumberedList(nil)
        check("…and toggles back off", e.string == "one\ntwo", e.string)
    }

    do {
        let e = makeEditor("a\nb\nc", select: NSRange(location: 0, length: 5))
        e.sahifaToggleQuote(nil)
        check("quote marks every selected line", e.string == "> a\n> b\n> c", e.string)
        e.sahifaToggleQuote(nil)
        check("…and toggles back off", e.string == "a\nb\nc", e.string)
    }

    // Selection must survive a toggle, or the next one only sees one line.
    do {
        let e = makeEditor("one\ntwo\nthree", select: NSRange(location: 0, length: 13))
        e.sahifaToggleBulletList(nil)
        check("three lines bulleted", e.string == "- one\n- two\n- three", e.string)
        check("…and all three stay selected",
              e.selectedRange().length == 19, "selected \(e.selectedRange())")
        e.sahifaToggleQuote(nil)
        check("a following toggle still sees every line",
              e.string == "> - one\n> - two\n> - three", e.string)
    }

    do {
        let e = makeEditor("one", select: NSRange(location: 2, length: 0))
        e.sahifaToggleBulletList(nil)
        check("a caret line is bulleted", e.string == "- one", e.string)
        check("…and the caret stays with its text",
              e.selectedRange().location == 4, "caret at \(e.selectedRange().location)")
    }

    // MARK: Undo

    do {
        let e = makeEditor("hello world", select: NSRange(location: 0, length: 5))
        e.sahifaToggleBold(nil)
        check("bold applied", e.string == "**hello** world", e.string)
        e.undoManager?.undo()
        check("one undo restores the whole formatting action",
              e.string == "hello world", e.string)
    }

    do {
        let e = makeEditor("one\ntwo", select: NSRange(location: 0, length: 7))
        e.sahifaToggleBulletList(nil)
        check("list applied", e.string == "- one\n- two", e.string)
        e.undoManager?.undo()
        check("one undo restores a multi-line list action",
              e.string == "one\ntwo", e.string)
    }

    do {
        let e = makeEditor("x", select: NSRange(location: 1, length: 0))
        e.sahifaInsertTable(nil)
        let inserted = e.string
        check("table inserted", inserted.contains("|"), inserted)
        e.undoManager?.undo()
        check("one undo removes an inserted table", e.string == "x", e.string)
    }

    // MARK: Tables from and to delimited text
    //
    // Private pasteboards throughout, so running the suite never touches the
    // user's clipboard.

    do {
        let board = NSPasteboard(name: NSPasteboard.Name("sahifa-test-paste-\(getpid())"))
        board.clearContents()
        board.setString("name\tcity\nمحمد\tالرياض\n", forType: .string)
        let e = makeEditor("Intro", select: NSRange(location: 5, length: 0))
        e.pasteTable(from: board)
        check("pasted cells become a table, set apart by a blank line",
              e.string == "Intro\n\n| name | city |\n| --- | --- |\n| محمد | الرياض |\n",
              e.string.debugDescription)
        check("…with the caret just after it",
              e.selectedRange().location == (e.string as NSString).length - 1, "\(e.selectedRange())")
        e.undoManager?.undo()
        check("one undo removes a pasted table", e.string == "Intro", e.string)
        board.releaseGlobally()
    }

    do {
        let board = NSPasteboard(name: NSPasteboard.Name("sahifa-test-crlf-\(getpid())"))
        board.clearContents()
        board.setString("a,b\n1,2", forType: .string)
        let e = makeEditor("Intro\r\n", select: NSRange(location: 7, length: 0))
        e.pasteTable(from: board)
        check("in a CRLF file, an existing CRLF counts as one line break, and new ones match",
              e.string == "Intro\r\n\r\n| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n", e.string.debugDescription)
        board.releaseGlobally()
    }

    do {
        let text = "before\n\na,b\n1,2\n\nafter"
        let e = makeEditor(text, select: (text as NSString).range(of: "a,b\n1,2"))
        e.sahifaConvertSelectionToTable(nil)
        check("a CSV selection converts in place without extra blank lines",
              e.string == "before\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter", e.string.debugDescription)
    }

    do {
        let e = makeEditor("just words", select: NSRange(location: 0, length: 10))
        e.sahifaConvertSelectionToTable(nil)
        check("a selection without columns is left alone", e.string == "just words", e.string)
    }

    do {
        let text = "Intro\n\n| name | note |\n| :--- | ---: |\n| Ali | says \"hi\", twice |\n| سارة | a \\| b |\n\nOutro"
        let caret = (text as NSString).range(of: "Ali").location
        let e = makeEditor(text, select: NSRange(location: caret, length: 0))
        let board = NSPasteboard(name: NSPasteboard.Name("sahifa-test-copy-\(getpid())"))
        check("copying from inside a table succeeds", e.copyTableAsCSV(to: board))
        let copied = board.string(forType: .string)
        check("…as CSV, quoted only where needed",
              copied == "name,note\nAli,\"says \"\"hi\"\", twice\"\nسارة,a | b\n",
              copied?.debugDescription ?? "nil")
        let outside = makeEditor(text, select: NSRange(location: 1, length: 0))
        check("outside a table there's nothing to copy", !outside.copyTableAsCSV(to: board))
        let quotedText = "> | a | b |\n> | --- | --- |\n> | 1 | 2 |\n"
        let quoted = makeEditor(quotedText,
                                select: NSRange(location: (quotedText as NSString).range(of: "1").location, length: 0))
        check("a table in a blockquote copies without its markers",
              quoted.copyTableAsCSV(to: board) && board.string(forType: .string) == "a,b\n1,2\n",
              board.string(forType: .string)?.debugDescription ?? "nil")
        board.releaseGlobally()
    }

    // MARK: Script-aware emphasis
    //
    // Arabic has no italic face, so emphasis that mapped to Arabic-Regular
    // rendered identically to body text. Emphasis must land on a *different*
    // face from its surroundings in both scripts.

    check("Plex faces registered for the font checks", registerPlexFonts())

    do {
        let body = FontLibrary.prose(size: 16)
        let latinEm = FontLibrary.prose(size: 16, italic: true)
        check("Latin emphasis is a true italic",
              latinEm.fontName.contains("Italic"), latinEm.fontName)
        check("…and differs from body text", latinEm.fontName != body.fontName)

        // The Arabic face is reached through the cascade, so compare the
        // cascade entry rather than the primary (Latin) font name.
        func arabicFace(_ font: NSFont) -> String {
            let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
            return cascade?.first?.object(forKey: .name) as? String ?? "<none>"
        }
        let arabicBody = arabicFace(body)
        let arabicEm = arabicFace(latinEm)
        check("Arabic body is the Regular face",
              arabicBody == "IBMPlexSansArabic-Regular", arabicBody)
        check("an italic Arabic run resolves to a different face than body text",
              arabicEm != arabicBody, "\(arabicBody) -> \(arabicEm)")
        check("…specifically one weight up",
              arabicEm == "IBMPlexSansArabic-Medium", arabicEm)

        // Bold is already the top Arabic weight: emphasis inside bold has
        // nowhere to go, and must not fall back to a lighter face.
        let arabicBoldEm = arabicFace(FontLibrary.prose(size: 16, weight: .bold, italic: true))
        check("bold Arabic emphasis stays bold",
              arabicBoldEm == "IBMPlexSansArabic-Bold", arabicBoldEm)

        // Regression: medium/semibold used to drop the italic argument.
        let mediumEm = FontLibrary.prose(size: 16, weight: .medium, italic: true)
        let semiboldEm = FontLibrary.prose(size: 16, weight: .semibold, italic: true)
        check("medium honours italic", mediumEm.fontName.contains("Italic"), mediumEm.fontName)
        check("semibold honours italic", semiboldEm.fontName.contains("Italic"), semiboldEm.fontName)
        check("medium Arabic emphasis steps up",
              arabicFace(mediumEm) == "IBMPlexSansArabic-SemiBold", arabicFace(mediumEm))
    }

    // MARK: Restyle must stay a fixed point
    //
    // A second pass over already-styled text has to make zero attribute edits,
    // or every keystroke re-lays-out the document and the view flickers.

    do {
        let mixed = """
        # عنوان مختلط Heading

        نص عربي فيه *مائل* وكلمة English with *emphasis* here.

        فقرة ثانية بالعربية مع **غامق** و `code`.

        A Latin paragraph with a [link](https://example.com) and _stress_.
        """
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let storage = NSTextStorage(string: mixed)
        styler.restyle(storage)
        let firstPass = NSAttributedString(attributedString: storage)
        styler.restyle(storage)
        check("restyle is a fixed point on mixed EN/AR text",
              firstPass.isEqual(to: storage))

        // The Arabic emphasis really lands in the storage, not just in the
        // font library: find *مائل* and check its font differs from the
        // paragraph around it.
        let ns = mixed as NSString
        let emRange = ns.range(of: "مائل")
        check("found the Arabic emphasis run", emRange.location != NSNotFound)
        if emRange.location != NSNotFound {
            let emFont = storage.attribute(.font, at: emRange.location, effectiveRange: nil) as? NSFont
            let bodyRange = ns.range(of: "نص عربي")
            let bodyFont = storage.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
            check("styled Arabic emphasis differs from the surrounding text",
                  emFont?.fontName != bodyFont?.fontName,
                  "\(bodyFont?.fontName ?? "?") -> \(emFont?.fontName ?? "?")")
        }
    }

    // MARK: Hardening round (2026-10-21)

    // ⌘I on a bold word adds italic; it used to read the inner "*" of "**"
    // as an italic marker and strip it, turning bold into italic.
    do {
        let e = makeEditor("**word**", select: NSRange(location: 2, length: 4))
        e.sahifaToggleItalic(nil)
        check("italic on a bold word makes it bold-italic", e.string == "***word***", e.string)
        e.sahifaToggleItalic(nil)
        check("…and toggles back to bold", e.string == "**word**", e.string)
    }
    do {
        let text = "*a* and *b*"
        let e = makeEditor(text, select: NSRange(location: 0, length: (text as NSString).length))
        e.sahifaToggleItalic(nil)
        check("a selection spanning two italic runs is wrapped, not mangled",
              e.string == "**a* and *b**", e.string)
    }
    do {
        let e = makeEditor("**bold**", select: NSRange(location: 0, length: 8))
        e.sahifaToggleItalic(nil)
        check("italic over a whole bold selection wraps it", e.string == "***bold***", e.string)
    }

    // CRLF: a code block adds no blank line and no LF; a heading toggles.
    do {
        let e = makeEditor("x\r\ncode\r\ny", select: NSRange(location: 4, length: 0))
        e.sahifaInsertCodeBlock(nil)
        check("a code block in a CRLF file keeps CRLF and adds no blank line",
              e.string == "x\r\n```\r\ncode\r\n```\r\ny", e.string.debugDescription)
        let h = makeEditor("#\r\nnext", select: NSRange(location: 0, length: 0))
        h.sahifaHeading1(nil)
        check("an empty CRLF heading toggles off", h.string == "\r\nnext", h.string.debugDescription)
    }

    // A CRLF document is styled past its first line.
    do {
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let text = "intro\r\n\r\n# Heading\r\n"
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        let at = (text as NSString).range(of: "Heading").location
        let size = (storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        check("a heading after CRLF lines is styled as a heading", size > 20, "\(size) pt")
        let lone = "intro\r# Heading\r"
        let loneStorage = NSTextStorage(string: lone)
        styler.restyle(loneStorage)
        let loneAt = (lone as NSString).range(of: "Heading").location
        let loneSize = (loneStorage.attribute(.font, at: loneAt, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        check("…and after a lone CR", loneSize > 20, "\(loneSize) pt")
    }

    // Copy as CSV works in a CRLF document.
    do {
        let board = NSPasteboard.withUniqueName()
        let text = "| a | b |\r\n| --- | --- |\r\n| 1 | 2 |\r\n"
        let e = makeEditor(text, select: NSRange(location: (text as NSString).range(of: "1").location, length: 0))
        check("Copy Table as CSV works with CRLF lines",
              e.copyTableAsCSV(to: board) && board.string(forType: .string) == "a,b\n1,2\n",
              board.string(forType: .string)?.debugDescription ?? "nil")
        board.releaseGlobally()
    }

    // Pasting an existing Markdown table keeps it a table; prose beeps.
    do {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setString("| a | b |\n| --- | --- |\n| 1 | 2 |", forType: .string)
        let e = makeEditor("", select: NSRange(location: 0, length: 0))
        e.pasteTable(from: board)
        check("pasting a Markdown table keeps its two columns",
              e.string.contains("| a | b |") && !e.string.contains("|  |") && !e.string.contains("| --- | --- |\n| --- |"),
              e.string.debugDescription)
        board.clearContents()
        board.setString("Just a sentence.", forType: .string)
        let prose = makeEditor("", select: NSRange(location: 0, length: 0))
        prose.pasteTable(from: board)
        check("prose isn't pasted as a one-column table", prose.string.isEmpty, prose.string.debugDescription)
        board.releaseGlobally()
    }

    // Text replaced from outside (another window on the same file, a reload)
    // drops the editor's undo history: replaying a step recorded against the
    // longer old text raised an out-of-bounds exception and crashed.
    do {
        let e = makeEditor("", select: NSRange(location: 0, length: 0))
        let coordinator = MarkdownEditor.Coordinator(
            MarkdownEditor(text: .constant(""), fontSize: 16, lineSpacing: 1.4))
        coordinator.textView = e
        e.insertText("a long line typed in this window", replacementRange: e.selectedRange())
        check("typing leaves something to undo", e.undoManager?.canUndo == true)
        let changed = coordinator.adoptExternalText("x")
        check("text from elsewhere replaces the editor's", changed && e.string == "x", e.string)
        check("…and clears undo steps that no longer fit", e.undoManager?.canUndo == false)
        e.undoManager?.undo()   // must not raise
        check("…so undo leaves the new text alone", e.string == "x", e.string)
        check("identical text is left alone", !coordinator.adoptExternalText("x"))
        check("canonically equivalent text still counts as a change",
              coordinator.adoptExternalText("cafe\u{301}") && coordinator.adoptExternalText("caf\u{E9}"))
    }

    // Only letters set a paragraph's direction, as with dir="auto".
    check("Arabic text is RTL", BidiDirection.firstStrong(in: "مرحبا") == .rightToLeft)
    check("digits before Arabic don't decide it", BidiDirection.firstStrong(in: "123 مرحبا") == .rightToLeft)
    check("Arabic-Indic digits are weak", BidiDirection.firstStrong(in: "١٢ apples") == .leftToRight)
    check("a byte-order mark is not a strong character",
          BidiDirection.firstStrong(in: "\u{FEFF}Name,Age") == .leftToRight)
    check("an Arabic comma is not either", BidiDirection.firstStrong(in: "، hello") == .leftToRight)

    // A list toggle over many lines is one change, and one undo.
    do {
        let lines = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let e = makeEditor(lines, select: NSRange(location: 0, length: (lines as NSString).length))
        let start = Date()
        e.sahifaToggleBulletList(nil)
        let elapsed = Date().timeIntervalSince(start)
        check("500 lines become a list", e.string.hasPrefix("- line 1\n- line 2") && e.string.hasSuffix("- line 500"))
        check("…in a single change", elapsed < 2, String(format: "%.2f s", elapsed))
        e.undoManager?.undo()
        check("…undone in one step", e.string == lines)
    }
}

MainActor.assumeIsolated { run() }
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
