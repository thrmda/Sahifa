import AppKit
import Markdown
import SwiftUI

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

/// Repeatable random edits: a failure names its seed and step.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A box the editor's binding writes into, standing in for DocumentModel.text.
final class TextBox { var text: String; init(_ text: String) { self.text = text } }

/// The editor wired the way MarkdownEditor.makeNSView wires it: the TextKit 2
/// stack, the coordinator as delegate, the styler observing the storage.
@MainActor
func makeCoordinatedEditor(_ text: String) -> (view: BidiTextView, box: TextBox, coordinator: MarkdownEditor.Coordinator) {
    let box = TextBox(text)
    let editor = MarkdownEditor(text: Binding(get: { box.text }, set: { box.text = $0 }),
                                fontSize: 16, lineSpacing: 1.4)
    let coordinator = editor.makeCoordinator()
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layoutManager.textContainer = container
    let view = BidiTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
    view.isRichText = false
    view.allowsUndo = true
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    coordinator.styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
    coordinator.attach(view, contentStorage: contentStorage, layoutManager: layoutManager)
    view.string = text
    coordinator.restyle()
    return (view, box, coordinator)
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

    // MARK: Undo reaches the document
    //
    // Under TextKit 2, undo and redo rewrite the storage without the
    // delegate's textDidChange. The binding, the styling and the direction
    // bars have to follow anyway, or the next SwiftUI update put the old
    // text back over the undone one and threw the undo history away.
    do {
        let (view, box, _) = makeCoordinatedEditor("Title\n\nBody")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        check("typing reaches the binding", box.text == "# Title\n\nBody", box.text)
        view.undoManager?.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check("undo reaches the binding", box.text == "Title\n\nBody", box.text)
        let size = (view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        check("…and the undone heading is styled as prose again", size == 16, "\(size) pt")
        view.undoManager?.redo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check("redo reaches the binding", box.text == "# Title\n\nBody", box.text)
        let again = (view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        check("…and is styled as a heading", again > 20, "\(again) pt")
    }

    // MARK: Review round two

    // A CSV has no Markdown blocks; typing in one restyled the whole file.
    do {
        var csv = "id,name,amount\n"
        for i in 0..<4000 { csv += "\(i),item \(i),\(i * 3)\n" }
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        styler.parsesMarkdown = false
        let storage = NSTextStorage(string: csv)
        styler.observeEdits(of: storage)
        styler.restyle(storage)
        storage.replaceCharacters(in: NSRange(location: storage.length / 2, length: 0),
                                  with: NSAttributedString(string: "x", attributes: styler.baseAttributes()))
        styler.restyleEdited(storage)
        check("typing in a table file restyles only the rows around the edit",
              styler.lastRestyledLength < 200, "\(styler.lastRestyledLength) of \(storage.length)")
    }

    // One long line (a paragraph pasted from a word processor) with inline
    // markup used to cost seconds a keystroke: every node's position walked
    // the line from its start.
    do {
        var line = ""
        while line.utf8.count < 20_000 { line += "نص عربي مع *تشديد* و `كود` and some English, " }
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let storage = NSTextStorage(string: line)
        styler.observeEdits(of: storage)
        styler.restyle(storage)
        storage.replaceCharacters(in: NSRange(location: storage.length / 2, length: 0),
                                  with: NSAttributedString(string: "x", attributes: styler.baseAttributes()))
        let began = CFAbsoluteTimeGetCurrent()
        styler.restyleEdited(storage)
        let took = CFAbsoluteTimeGetCurrent() - began
        check("a keystroke in a 20 KB single-line Arabic paragraph stays well under half a second",
              took < 0.4, String(format: "%.0f ms", took * 1000))
    }

    // "]:" inside a code block is not a link reference definition.
    do {
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let storage = NSTextStorage(string: "intro\n\n```\narr[i]: x\n```\n\nmore text here\n")
        styler.observeEdits(of: storage)
        styler.restyle(storage)
        let rebuilds = styler.fullRebuilds
        storage.replaceCharacters(in: NSRange(location: 2, length: 0),
                                  with: NSAttributedString(string: "y", attributes: styler.baseAttributes()))
        styler.restyleEdited(storage)
        check("a bracket-colon in code does not force a full restyle", styler.fullRebuilds == rebuilds)
    }

    // Reference-style links: the definitions are read by links anywhere, and
    // used to put the whole document through the parser on every keystroke.
    // Now they are parsed along with the window around the edit; only an
    // edit that changes which labels are defined rebuilds everything.
    do {
        var long = "Read [the guide][guide] and [the notes][notes].\n\n"
        for i in 0..<60 {
            long += "## Section \(i)\n\nProse with a [link][guide] and `code`.\n\n- one\n- two\n\nفقرة \(i).\n\n"
        }
        long += "[guide]: https://example.com/guide\n[notes]: https://example.com/notes \"Notes\"\n"
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let storage = NSTextStorage(string: long)
        styler.observeEdits(of: storage)
        styler.restyle(storage)
        let ns = { storage.string as NSString }
        func type(_ text: String, at location: Int) {
            storage.replaceCharacters(in: NSRange(location: location, length: 0),
                                      with: NSAttributedString(string: text, attributes: styler.baseAttributes()))
            styler.restyleEdited(storage)
        }
        func matchesFullRestyle() -> Bool {
            let fresh = NSTextStorage(string: storage.string)
            let reference = MarkdownStyler()
            reference.theme = styler.theme
            reference.restyle(fresh)
            return fresh.isEqual(to: storage)
        }
        var rebuilds = styler.fullRebuilds
        let middle = ns().range(of: "Prose", options: [], range: NSRange(location: ns().length / 2, length: ns().length / 2)).location
        for typed in ["x", "\n\n", "[link][guide]", "[none][missing]"] { type(typed, at: middle) }
        check("typing in a document with reference definitions restyles only around the edit",
              styler.fullRebuilds == rebuilds, "\(styler.fullRebuilds - rebuilds) full rebuilds")
        check("…and links there resolve against definitions outside the parsed window", matchesFullRestyle())
        let linkAt = ns().range(of: "[link][guide]", options: [], range: NSRange(location: middle, length: 60)).location
        check("…a reference link is styled as a link",
              storage.attribute(.underlineStyle, at: linkAt + 1, effectiveRange: nil) != nil)
        let missingAt = ns().range(of: "[none][missing]").location
        check("…and one with no definition is not",
              storage.attribute(.underlineStyle, at: missingAt + 1, effectiveRange: nil) == nil)

        rebuilds = styler.fullRebuilds
        type("x", at: NSMaxRange(ns().range(of: "example.com/guide")))
        check("typing in a definition's URL does not rebuild everything",
              styler.fullRebuilds == rebuilds && matchesFullRestyle())

        rebuilds = styler.fullRebuilds
        type("x", at: ns().range(of: "[guide]: https").location + 1)
        check("changing a definition's label rebuilds everything", styler.fullRebuilds == rebuilds + 1)
        check("…so links that lost their definition are plain again", matchesFullRestyle())
        type("x", at: ns().range(of: "[notes]: https").location + 1)
        type("\n\nAfter.", at: ns().length)
        check("…and the document stays exact once no definition is left", matchesFullRestyle())

        // A definition inside a quote only a full parse can place.
        type("\n\n> [quoted]: https://example.com/q\n\n", at: 0)
        type("y", at: middle + 40)
        check("a definition inside a quote stays exact", matchesFullRestyle())

        // Parsing the whole document on every keystroke cost a full parse
        // each; the window around the edit costs a fraction of one. Measured
        // against a parse of the same text, so the machine's speed and load
        // fall out.
        var big = ""
        while big.utf8.count < 300_000 { big += long }
        let bigStyler = MarkdownStyler()
        bigStyler.theme = styler.theme
        let bigStorage = NSTextStorage(string: big)
        bigStyler.observeEdits(of: bigStorage)
        bigStyler.restyle(bigStorage)
        let at = (big as NSString).range(of: "Prose", options: [], range: NSRange(location: big.utf16.count / 2, length: big.utf16.count / 2)).location
        let started = Date()
        for i in 0..<20 {
            bigStorage.replaceCharacters(in: NSRange(location: at + i, length: 0),
                                         with: NSAttributedString(string: "x", attributes: bigStyler.baseAttributes()))
            bigStyler.restyleEdited(bigStorage)
        }
        let elapsed = Date().timeIntervalSince(started)
        let parsing = Date()
        for _ in 0..<20 { _ = Document(parsing: bigStorage.string) }
        let fullParses = Date().timeIntervalSince(parsing)
        check("20 keystrokes in a 300 KB document with reference definitions cost under half of 20 full parses",
              elapsed < fullParses / 2, String(format: "%.2f s against %.2f s", elapsed, fullParses))
    }

    // A rule and a table in a CRLF file keep its line endings, with no
    // extra blank line.
    do {
        let e = makeEditor("a\r\nb", select: NSRange(location: 1, length: 0))
        e.sahifaInsertHorizontalRule(nil)
        check("a rule in a CRLF file keeps CRLF", e.string == "a\r\n\r\n---\r\n\r\nb", e.string.debugDescription)
        let t = makeEditor("a", select: NSRange(location: 1, length: 0))
        e.undoManager?.removeAllActions()
        t.sahifaInsertTable(nil)
        check("a table at the end of a file adds one blank line and ends the file",
              t.string == "a\n\n| Column | Column |\n| --- | --- |\n|  |  |\n", t.string.debugDescription)
        check("…with the first Column selected", t.selectedRange() == NSRange(location: 5, length: 6),
              "\(t.selectedRange())")
    }

    // Arabic-Indic digits are prose to cmark, so a numbered list is added.
    do {
        let e = makeEditor("١. foo", select: NSRange(location: 0, length: 0))
        e.sahifaToggleNumberedList(nil)
        check("a line starting with Arabic digits gets a list marker", e.string == "1. ١. foo", e.string)
    }

    // A heading indented by up to three spaces is still a heading.
    do {
        let e = makeEditor("  # x", select: NSRange(location: 3, length: 0))
        e.sahifaHeading1(nil)
        check("an indented heading toggles off instead of stacking", e.string == "x", e.string)
    }

    // MARK: Restyling only what an edit changed
    //
    // Typing restyles just the blocks an edit touched. Whatever the edit,
    // that has to land exactly where restyling the whole document would.

    do {
        let seed = """
        # عنوان Heading

        Intro paragraph with *emphasis* and a [link][ref].

        - item one
        - عنصر ثاني
          continued

        > quoted **bold**
        > سطر

        ```
        let x = 1
        ```

        | a | b |
        | --- | --- |
        | 1 | ٢ |

        Title
        =====

        123

        نص عربي فيه `code` و ~~شطب~~.\r\nCRLF line\r\n\r\n1. numbered

        [ref]: https://example.com
        """
        let snippets = ["x", "ب", "\n", "\n\n", "# ", "*", "**", "`", "```\n", "~~~", "> ", "- ", "1. ",
                        "| c |", "---", "===", "]: https://e.com", "[ref]", "\r\n", " ", "123", "مرحبا", "_"]
        var mismatches = 0
        var firstMismatch = ""
        // Without link reference definitions only a window around each edit
        // is parsed again; with them, the whole document is.
        let plain = seed.replacingOccurrences(of: "\n\n[ref]: https://example.com", with: "")
        for (seedValue, markdown, references) in [(1, true, true), (2, true, true), (3, true, false),
                                                  (4, true, false), (5, true, false), (6, false, true)] {
            var generator = SeededGenerator(seed: UInt64(seedValue))
            let snippets = references ? snippets : snippets.filter { !$0.contains("]:") }
            var styler = MarkdownStyler()
            styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
            styler.parsesMarkdown = markdown
            let storage = NSTextStorage(string: references ? seed : plain)
            styler.observeEdits(of: storage)
            styler.restyle(storage)
            for step in 0..<400 {
                let length = storage.length
                let location = Int.random(in: 0...length, using: &generator)
                let removal = Int.random(in: 0...3, using: &generator) == 0
                    ? min(Int.random(in: 0...12, using: &generator), length - location) : 0
                let insertion = Int.random(in: 0...4, using: &generator) == 0 ? "" : snippets.randomElement(using: &generator)!
                // As typing does: the new text arrives with plain attributes.
                storage.replaceCharacters(in: NSRange(location: location, length: removal),
                                          with: NSAttributedString(string: insertion, attributes: styler.baseAttributes()))
                if Int.random(in: 0...5, using: &generator) == 0 {
                    styler.focusParagraph = Int.random(in: 0...2, using: &generator) == 0 ? nil
                        : (storage.string as NSString).paragraphRange(
                            for: NSRange(location: Int.random(in: 0...storage.length, using: &generator), length: 0))
                }
                styler.restyleEdited(storage)

                let reference = MarkdownStyler()
                reference.theme = styler.theme
                reference.parsesMarkdown = markdown
                reference.focusParagraph = styler.focusParagraph
                let fresh = NSTextStorage(string: storage.string)
                reference.restyle(fresh)
                if !fresh.isEqual(to: storage) {
                    mismatches += 1
                    if firstMismatch.isEmpty { firstMismatch = "seed \(seedValue), step \(step)" }
                    // Start over with a fresh styler: the patched one's cache
                    // is what went wrong, and restyling from it kept the
                    // mismatch for every step after.
                    styler = MarkdownStyler()
                    styler.theme = reference.theme
                    styler.parsesMarkdown = markdown
                    styler.focusParagraph = reference.focusParagraph
                    styler.observeEdits(of: storage)
                    styler.restyle(storage)
                }
            }
        }
        check("restyling only the edit matches restyling everything, over 2400 random edits",
              mismatches == 0, mismatches == 0 ? "" : "\(mismatches) mismatches; first at \(firstMismatch)")
    }

    // Typing in a long document restyles only around the edit: anywhere in
    // a paragraph, at its end, on a new line, in a list or a code block.
    do {
        var long = ""
        for i in 0..<60 {
            long += "## Section \(i)\n\nA paragraph of prose with *emphasis* and `code`.\n\n"
            long += "- one\n- two\n\n```\nlet x = \(i)\n```\n\nفقرة عربية \(i).\n\n"
        }
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let storage = NSTextStorage(string: long)
        styler.observeEdits(of: storage)
        styler.restyle(storage)
        let rebuilds = styler.fullRebuilds
        let ns = { storage.string as NSString }
        let places = [
            ns().range(of: "prose", options: [], range: NSRange(location: ns().length / 2, length: ns().length / 2)).location,
            NSMaxRange(ns().range(of: "`code`.", options: [], range: NSRange(location: ns().length / 3, length: ns().length / 3))),
            NSMaxRange(ns().range(of: "- two", options: [], range: NSRange(location: ns().length / 2, length: ns().length / 2))),
            ns().range(of: "let x", options: [], range: NSRange(location: ns().length / 2, length: ns().length / 2)).location,
            NSMaxRange(ns().range(of: "عربية", options: [], range: NSRange(location: ns().length / 2, length: ns().length / 2))),
        ]
        for place in places {
            for typed in ["x", "\n", "y"] {
                let at = place + (typed == "y" ? 1 : 0)
                storage.replaceCharacters(in: NSRange(location: at, length: 0),
                                          with: NSAttributedString(string: typed, attributes: styler.baseAttributes()))
                styler.restyleEdited(storage)
            }
        }
        check("typing in a long document never restyles all of it",
              styler.fullRebuilds == rebuilds, "\(styler.fullRebuilds - rebuilds) full rebuilds")
        let fresh = NSTextStorage(string: storage.string)
        let reference = MarkdownStyler()
        reference.theme = styler.theme
        reference.restyle(fresh)
        check("…and comes out the same as restyling it all", fresh.isEqual(to: storage))
    }

    // Edits that once came out differently from a full restyle: cmark's
    // source ranges can overlap or run past a block around CR line endings
    // and open fences, and which of two equal neighbours was typed can only
    // come from the storage.
    do {
        let replays: [(String, String, Int, Int, String)] = [
            ("a newline typed beside another newline",
             "# ع| c |نوان Heading\n\nInaragraph with *emphasis* a*nd\n\n.\n[ref]m one\n- \n\nعنصر ث---اني\n  c*ont\ni1x**1.  ```\nn*ued\n\n> qxuoted **boمرحباld**\n123> سطر\n\n| [ref]c |```\nlet x = 1\n```مرحبا\n\n**| a | b |\n| --- | --[ref]- |\n| 1ب ٢ |\n\nTitl=1. | c |\nنص عربي في---~~شطب~~.\r\nCRLF line\r\n\r\n1. - numb`ered\n\n[ref]: htxtps://example.com",
             70, 0, "\n"),
            ("an open fence inside a quote",
             "#==> =ان H`g\n\n\r\nInt123_ph|\r\n*=\r\n [l`ink][rب===1. ef\r\nte\r\n# m_ ```م\n\nرحبا*xن===صر-123  ث--- ا```=>- مرحبا`2```\n3t_*\n1```===1_.\n \n[reب- f]3*===ط1. ر\n\n````ب`123\n# l`x\r\n = 1\n12\n\n3`x`# ~~~`\n| x---c |x ```\n> ```\nref]*xم| c |رح*~ب|> T \n===[rx\n\n ~~~ef]---~~~1. \r\n=> \n12~~_~3\n_**r#1.  e```x`\n# f\r\n]\n> \nر> \n\nببي1x.  # >~~~ x-  ~1# 2c 11. .\n\n  \n\n\n\nمرحبا`123**--ب-1. ب c |1. \n\n=li#  >~> ~~ n1. > 2*3\r\nب````~~**~\n--~~~-``\n\n\n\n\n1. ===u1- . mbمر-\r\n--حباx",
             259, 0, "\n"),
            ("a setext underline over CRLF",
             "| c |# عبمر\n- \r\nحبا\n##  \n1._ ~\n\n~ب*_\nب# ا3*** and| c | a [l> in> - k1.# -1.  it e *| c |* c |رحببا\no** ne\n-x | c \r===123xنص*# *ر ث| c |_`م123رحباان---ب[ref]> \n*يx*t``e**d1.  `*\n*1. `ب _\n >\n==\r\n=\n`\nl*e===t  1\n``-> \n\n**a| c | | b-[ref   | c ||\r\nب\n| -ب-> |>x مرحبا 1 \n\n | \n\n٢# ب |---\n\n---\n- T\n\n112323i~~~=12**31. - 23\n\n`\nب- ب- `cod`\r\n[ref]| c |x~_~~~===.\n\r\nCRLF~~مرحبا~l# -| c| c |. ا2> 3`",
             14, 0, "# "),
            ("a lone CR beside a setext heading",
             "# `di```\nf].| c | p\n\nara===gr\nap~~~h11. . | ]: https://x3e.c_om **# c# -_- ]: httpمرحباomit\n*_h[[ref]e * مرحبا| c |an`1---.--xx > /e.com|\n c |=\n\nd\n\n>]\n_[ref]_\n]:` http#]: https:[r- ef]/# /e.com~~~.com`*:/| c |\r\n# *\n-`````\n`\n [re1. f> ] [ref]e\r-\r\n -x-\n**1`23 ~~~12| c -`--|3`\n\n1xب\n===\n b |ب> : ---https:123~~~//e.c\n12 بي>  **فبxي# ```1. c1. \n|`]\r\n: ht`* ]: بht```\ncom c ```\ntps://===.\n=x== `\r\n\r**رمرحبا_حب [re1. f]: https://e.com\nef|  tps:/- co\nm] : 1---2\n\n31**. - \nt**\n\n`p\n\n1231. *\r\nf]: h---ttps:/| c |/e.com",
             246, 1, "")
        ]
        for (name, before, location, removal, insertion) in replays {
            let styler = MarkdownStyler()
            styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
            let storage = NSTextStorage(string: before)
            styler.observeEdits(of: storage)
            styler.restyle(storage)
            storage.replaceCharacters(in: NSRange(location: location, length: removal),
                                      with: NSAttributedString(string: insertion, attributes: styler.baseAttributes()))
            styler.restyleEdited(storage)
            let fresh = NSTextStorage(string: storage.string)
            let reference = MarkdownStyler()
            reference.theme = styler.theme
            reference.restyle(fresh)
            check("restyling only the edit is exact after \(name)", fresh.isEqual(to: storage))
        }
    }

    // A fence left open inside a quote ends with the quote; cmark's range
    // for it runs on over the next line, which used to turn that line into code.
    do {
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let text = "> ```\nnext para"
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        let at = (text as NSString).range(of: "next").location
        let font = storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont
        check("the line after an open fence in a quote is not code",
              font.map { !$0.fontName.contains("Mono") } == true, font?.fontName ?? "nil")
    }

    // A setext heading over CRLF lines: cmark's range for it runs into the
    // next line, which used to set that line at heading size too.
    do {
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let text = "Title\n- \r\nnext line"
        let storage = NSTextStorage(string: text)
        styler.restyle(storage)
        let size = { (word: String) -> CGFloat in
            let at = (text as NSString).range(of: word).location
            return (storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
        check("a CRLF setext heading is a heading", size("Title") > 20, "\(size("Title")) pt")
        check("…and the line after it is not", size("next") == 16, "\(size("next")) pt")
    }

    // A paragraph with no letters takes the direction of the one before it,
    // so turning that one Arabic has to restyle the paragraphs after it too.
    do {
        let styler = MarkdownStyler()
        styler.theme = EditorTheme(fontSize: 16, lineHeightMultiple: 1.4)
        let storage = NSTextStorage(string: "abc\n\n123\n\n456\n\nxyz")
        styler.observeEdits(of: storage)
        styler.restyle(storage)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                  with: NSAttributedString(string: "ب", attributes: styler.baseAttributes()))
        styler.restyleEdited(storage)
        let digits = (storage.string as NSString).range(of: "456").location
        check("a number-only paragraph follows the paragraph before it into RTL",
              storage.attribute(.sahifaDirection, at: digits, effectiveRange: nil) as? Int == 1)
        let latin = (storage.string as NSString).range(of: "xyz").location
        check("…and the next paragraph with letters keeps its own direction",
              storage.attribute(.sahifaDirection, at: latin, effectiveRange: nil) as? Int == 0)
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

    // MARK: Long tail (2026-10-21)

    // Japanese and other composed input: while a character is being put
    // together (marked text), focus mode restyles on every selection change.
    // That must leave the composition alone, and the document gets the text
    // only once it is confirmed.
    do {
        let (view, box, coordinator) = makeCoordinatedEditor("Title\n\nBody\n\nMore")
        coordinator.focusMode = true
        _ = coordinator.updateFocusParagraph()
        coordinator.restyle()
        let at = (view.string as NSString).range(of: "Body").location + 4
        view.setSelectedRange(NSRange(location: at, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let fullRebuilds = coordinator.styler.fullRebuilds
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check("a composition in progress is marked",
              view.hasMarkedText() && view.markedRange() == NSRange(location: at, length: 1),
              NSStringFromRange(view.markedRange()))
        check("…and not yet in the document", box.text == "Title\n\nBody\n\nMore", box.text)
        view.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check("…a longer composition stays marked",
              view.hasMarkedText() && view.markedRange() == NSRange(location: at, length: 2),
              NSStringFromRange(view.markedRange()))
        view.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check("confirming the composition puts it in the document",
              !view.hasMarkedText() && box.text == "Title\n\nBody漢\n\nMore", box.text)
        check("…without restyling everything", coordinator.styler.fullRebuilds == fullRebuilds,
              "\(coordinator.styler.fullRebuilds - fullRebuilds) full rebuilds")
        let fresh = NSTextStorage(string: view.string)
        let reference = MarkdownStyler()
        reference.theme = coordinator.styler.theme
        reference.focusParagraph = coordinator.styler.focusParagraph
        reference.restyle(fresh)
        check("…and the styling is exact", fresh.isEqual(to: view.textStorage!))
        let dim = view.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let focus = view.textStorage!.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor
        check("…with the composed paragraph in focus and the title dimmed",
              dim.map { $0.alphaComponent < 1 } == true && focus.map { $0.alphaComponent == 1 } == true)
    }
}

MainActor.assumeIsolated { run() }
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
