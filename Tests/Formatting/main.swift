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
}

MainActor.assumeIsolated { run() }
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
