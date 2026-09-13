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
}

MainActor.assumeIsolated { run() }
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
