import AppKit
import Markdown

/// Markdown formatting actions, reachable from the Format menu (and its
/// keyboard shortcuts) via the responder chain — the menu sends these
/// selectors to the first responder, so they land on the focused editor.
extension BidiTextView {

    @objc func sahifaToggleBold(_ sender: Any?) {
        toggleInlineDelimiter("**")
    }

    @objc func sahifaToggleItalic(_ sender: Any?) {
        toggleInlineDelimiter("*")
    }

    @objc func sahifaToggleStrikethrough(_ sender: Any?) {
        toggleInlineDelimiter("~~")
    }

    @objc func sahifaToggleInlineCode(_ sender: Any?) {
        toggleInlineDelimiter("`")
    }

    @objc func sahifaHeading1(_ sender: Any?) { toggleHeading(level: 1) }
    @objc func sahifaHeading2(_ sender: Any?) { toggleHeading(level: 2) }
    @objc func sahifaHeading3(_ sender: Any?) { toggleHeading(level: 3) }
    @objc func sahifaHeading4(_ sender: Any?) { toggleHeading(level: 4) }

    @objc func sahifaToggleBulletList(_ sender: Any?) { toggleParagraphMarker(.bullet) }
    @objc func sahifaToggleNumberedList(_ sender: Any?) { toggleParagraphMarker(.numbered) }
    @objc func sahifaToggleQuote(_ sender: Any?) { toggleParagraphMarker(.quote) }

    /// Wraps the selected paragraphs (or the caret's paragraph) in a fenced
    /// code block.
    @objc func sahifaInsertCodeBlock(_ sender: Any?) {
        let ns = string as NSString
        let paragraphs = ns.paragraphRange(for: selectedRange())
        let lineBreak = documentLineBreak
        var body = ns.substring(with: paragraphs)
        // Checked by code unit: "\r\n" is a single Character in Swift, so
        // hasSuffix("\n") is false for a CRLF line and a second break got added.
        let trailing = Self.trailingLineBreakLength(of: body)
        if (body as NSString).length == trailing { body = lineBreak }
        else if trailing == 0 { body += lineBreak }
        let fence = "```"
        let fenced = fence + lineBreak + body + fence + lineBreak
        // Caret at the end of the wrapped content (just before its line break).
        let caret = paragraphs.location + (fence + lineBreak + body as NSString).length
            - Self.trailingLineBreakLength(of: body)
        replace(paragraphs, with: fenced, selecting: NSRange(location: caret, length: 0))
    }

    /// The document's own line ending, so an inserted block doesn't leave a
    /// CRLF file with a mix.
    private var documentLineBreak: String {
        (string as NSString).range(of: "\r\n").location != NSNotFound ? "\r\n" : "\n"
    }

    /// UTF-16 length of the line break `text` ends with: 2 for CRLF, 1 for LF
    /// or CR, 0 for none.
    private static func trailingLineBreakLength(of text: String) -> Int {
        let units = Array(text.utf16.suffix(2))
        if units == [13, 10] { return 2 }
        if let last = units.last, last == 10 || last == 13 { return 1 }
        return 0
    }

    @objc func sahifaInsertLink(_ sender: Any?) {
        insertLinkTemplate(prefix: "[")
    }

    @objc func sahifaInsertImage(_ sender: Any?) {
        insertLinkTemplate(prefix: "![")
    }

    @objc func sahifaInsertHorizontalRule(_ sender: Any?) {
        insertBlock("---", replacing: selectedRange())
    }

    @objc func sahifaInsertTable(_ sender: Any?) {
        // Land with the first "Column" selected, ready to type over.
        insertBlock("| Column | Column |\n| --- | --- |\n|  |  |", replacing: selectedRange(),
                    selecting: NSRange(location: 2, length: 6))
    }

    // MARK: Tables from and to delimited text

    /// Whatever's on the clipboard as a Markdown table. Cells copied from
    /// Numbers or Excel arrive tab-separated; anything else has its delimiter
    /// detected.
    @objc func sahifaPasteAsTable(_ sender: Any?) {
        pasteTable(from: .general)
    }

    /// The selected CSV or TSV text as a Markdown table. A selection that
    /// doesn't split into at least two columns is left alone.
    @objc func sahifaConvertSelectionToTable(_ sender: Any?) {
        let selection = selectedRange()
        let rows = Self.tableRows(from: (string as NSString).substring(with: selection))
        guard selection.length > 0, (rows.map(\.count).max() ?? 0) >= 2 else {
            NSSound.beep()
            return
        }
        insertBlock(MarkdownTable.markdown(from: rows), replacing: selection)
    }

    /// The Markdown table the caret is in, as CSV on the clipboard.
    @objc func sahifaCopyTableAsCSV(_ sender: Any?) {
        copyTableAsCSV(to: .general)
    }

    /// Takes the pasteboard so tests can use a private one rather than the
    /// user's clipboard.
    func pasteTable(from pasteboard: NSPasteboard) {
        let tabSeparated = pasteboard.string(forType: .init("public.utf8-tab-separated-values-text"))
        guard let text = tabSeparated ?? pasteboard.string(forType: .string) else {
            NSSound.beep()
            return
        }
        let rows = tabSeparated != nil
            ? DelimitedText(parsing: text, delimiter: .tab).rows
            : Self.tableRows(from: text)
        // One column is prose, not a table; say so rather than box it up.
        guard (rows.map(\.count).max() ?? 0) >= 2 else {
            NSSound.beep()
            return
        }
        insertBlock(MarkdownTable.markdown(from: rows), replacing: selectedRange())
    }

    /// Rows from text that is either delimited or already a Markdown table.
    private static func tableRows(from text: String) -> [[String]] {
        MarkdownTable.looksLikeMarkdownTable(text)
            ? MarkdownTable.rows(fromSource: text)
            : DelimitedText(parsing: text).rows
    }

    @discardableResult
    func copyTableAsCSV(to pasteboard: NSPasteboard) -> Bool {
        guard let source = markdownTableSource(at: selectedRange().location) else {
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(MarkdownTable.csv(from: MarkdownTable.rows(fromSource: source)),
                             forType: .string)
        return true
    }

    /// The source lines of the Markdown table containing `location`. Found
    /// with swift-markdown, so what counts as a table is exactly what the
    /// preview renders as one.
    private func markdownTableSource(at location: Int) -> String? {
        let text = string
        let ns = text as NSString
        let map = SourceMap(text: text)
        func search(_ markup: Markup, quoted: Bool) -> String? {
            if let table = markup as? Markdown.Table {
                guard let sourceRange = table.range, let range = map.nsRange(sourceRange),
                      location >= range.location, location <= NSMaxRange(range),
                      NSMaxRange(range) <= ns.length
                else { return nil }
                let lines = ns.substring(with: ns.lineRange(for: range))
                return quoted ? MarkdownTable.strippingQuoteMarkers(lines) : lines
            }
            for child in markup.children {
                if let found = search(child, quoted: quoted || markup is BlockQuote) { return found }
            }
            return nil
        }
        return search(Document(parsing: text), quoted: false)
    }

    /// Replaces `range` with a block, adding only the line breaks needed to
    /// set it apart by a blank line, and leaves the caret just after it.
    /// `selecting` is within the block; the caret lands after it otherwise.
    private func insertBlock(_ block: String, replacing range: NSRange, selecting: NSRange? = nil) {
        let ns = string as NSString
        // In the document's own line endings, so a CRLF file doesn't come out
        // with a mix.
        let lineBreak = documentLineBreak
        let atStart = range.location == 0
        let atEnd = NSMaxRange(range) == ns.length
        let before = atStart ? 2 : lineBreaks(in: ns, endingAt: range.location)
        let after = lineBreaks(in: ns, startingAt: NSMaxRange(range))
        let prefix = String(repeating: lineBreak, count: max(0, 2 - before))
        // The end of the document only needs the line to end.
        let suffix = String(repeating: lineBreak, count: max(0, (atEnd ? 1 : 2) - after))
        let body = block.replacingOccurrences(of: "\n", with: lineBreak)
        let bodyStart = range.location + (prefix as NSString).length
        let selection = selecting.map { NSRange(location: bodyStart + $0.location, length: $0.length) }
            ?? NSRange(location: bodyStart + (body as NSString).length, length: 0)
        replace(range, with: prefix + body + suffix, selecting: selection)
    }

    /// Line breaks directly before `end`, up to two. CRLF counts once.
    private func lineBreaks(in ns: NSString, endingAt end: Int) -> Int {
        var count = 0
        var index = end
        while count < 2, index > 0 {
            switch ns.character(at: index - 1) {
            case 10: index -= index >= 2 && ns.character(at: index - 2) == 13 ? 2 : 1
            case 13: index -= 1
            default: return count
            }
            count += 1
        }
        return count
    }

    /// Line breaks directly from `start`, up to two. CRLF counts once.
    private func lineBreaks(in ns: NSString, startingAt start: Int) -> Int {
        var count = 0
        var index = start
        while count < 2, index < ns.length {
            switch ns.character(at: index) {
            case 13: index += index + 1 < ns.length && ns.character(at: index + 1) == 10 ? 2 : 1
            case 10: index += 1
            default: return count
            }
            count += 1
        }
        return count
    }

    /// `[selection](url)` / `![selection](url)` with "url" selected so the
    /// destination can be typed immediately.
    private func insertLinkTemplate(prefix: String) {
        let ns = string as NSString
        let sel = selectedRange()
        let label = ns.substring(with: sel)
        let replacement = prefix + label + "](url)"
        let urlStart = sel.location + (prefix as NSString).length + sel.length + 2
        replace(sel, with: replacement, selecting: NSRange(location: urlStart, length: 3))
    }

    // MARK: Inline delimiters (bold/italic)

    /// Wraps the selection in `delimiter`, or unwraps if it is already
    /// wrapped (either inside the selection or just around it). With an
    /// empty selection, inserts a delimiter pair and parks the caret inside.
    private func toggleInlineDelimiter(_ delimiter: String) {
        let ns = string as NSString
        let d = (delimiter as NSString).length
        let sel = selectedRange()

        // The selection itself starts and ends with the delimiter → strip it.
        // Only when nothing inside repeats it: "*a* and *b*" is two runs, not
        // one, and "**word**" under ⌘I is bold to add italic to, not italic
        // to remove.
        if sel.length >= 2 * d {
            let selected = ns.substring(with: sel)
            if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter) {
                let inner = String(selected.dropFirst(delimiter.count).dropLast(delimiter.count))
                if !inner.contains(delimiter) {
                    replace(sel, with: inner,
                            selecting: NSRange(location: sel.location, length: (inner as NSString).length))
                    return
                }
            }
        }

        // Delimiters sit immediately outside the selection → remove them.
        // For italic the run of asterisks on each side has to be odd: "**"
        // around a word is bold, and its inner "*" isn't an italic marker.
        if sel.location >= d, NSMaxRange(sel) + d <= ns.length,
           ns.substring(with: NSRange(location: sel.location - d, length: d)) == delimiter,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: d)) == delimiter,
           delimiter != "*" || (Self.asteriskRun(in: ns, endingAt: sel.location) % 2 == 1
                                && Self.asteriskRun(in: ns, startingAt: NSMaxRange(sel)) % 2 == 1) {
            let outer = NSRange(location: sel.location - d, length: sel.length + 2 * d)
            let inner = ns.substring(with: sel)
            replace(outer, with: inner,
                    selecting: NSRange(location: outer.location, length: sel.length))
            return
        }

        // Wrap. Empty selection ends up with the caret between the pair.
        let wrapped = delimiter + ns.substring(with: sel) + delimiter
        replace(sel, with: wrapped,
                selecting: NSRange(location: sel.location + d, length: sel.length))
    }

    private static func asteriskRun(in ns: NSString, endingAt end: Int) -> Int {
        var count = 0
        while end - count > 0, ns.character(at: end - count - 1) == 42 { count += 1 }
        return count
    }

    private static func asteriskRun(in ns: NSString, startingAt start: Int) -> Int {
        var count = 0
        while start + count < ns.length, ns.character(at: start + count) == 42 { count += 1 }
        return count
    }

    // MARK: Headings

    /// Sets every paragraph touched by the selection to `level`, or back to
    /// body text when it is already at that level.
    private func toggleHeading(level: Int) {
        let ns = string as NSString
        guard ns.length > 0 else {
            replace(NSRange(location: 0, length: 0),
                    with: String(repeating: "#", count: level) + " ", selecting: nil)
            return
        }

        let selection = ns.paragraphRange(for: selectedRange())
        var paragraphs: [NSRange] = []
        var location = selection.location
        while location < NSMaxRange(selection) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            guard NSMaxRange(paragraph) > location else { break }
            location = NSMaxRange(paragraph)
        }
        if paragraphs.isEmpty { paragraphs = [selection] }

        let marker = String(repeating: "#", count: level) + " "
        var edits: [(NSRange, String)] = []
        for paragraph in paragraphs {
            let line = ns.substring(with: paragraph)

            var hashes = 0
            var index = line.startIndex
            // Up to three spaces of indentation still make a heading.
            var indent = 0
            while index < line.endIndex, line[index] == " ", indent < 3 {
                indent += 1
                index = line.index(after: index)
            }
            while index < line.endIndex, line[index] == "#", hashes < 6 {
                hashes += 1
                index = line.index(after: index)
            }
            var prefixLength = 0
            if hashes > 0, index == line.endIndex || line[index] == " " || line[index].isNewline {
                while index < line.endIndex, line[index] == " " {
                    index = line.index(after: index)
                }
                prefixLength = line[line.startIndex..<index].utf16.count
            }

            let existing = prefixLength > 0 ? hashes : 0
            let prefixRange = NSRange(location: paragraph.location, length: prefixLength)
            let replacement = existing == level ? "" : marker
            edits.append((prefixRange, replacement))
        }
        applyParagraphEdits(edits, spanning: selection)
    }

    // MARK: List / quote markers

    private enum ParagraphMarker {
        case bullet, numbered, quote
    }

    /// Toggles a paragraph-level marker on every non-blank paragraph in the
    /// selection. If all of them already carry it, it is removed; otherwise
    /// it is added (replacing a competing list marker, so bullet ⇄ numbered
    /// converts in place). Numbered lists count 1., 2., … down the selection.
    private func toggleParagraphMarker(_ marker: ParagraphMarker) {
        let ns = string as NSString
        guard ns.length > 0 else {
            let prefix = marker == .quote ? "> " : (marker == .bullet ? "- " : "1. ")
            replace(NSRange(location: 0, length: 0), with: prefix, selecting: nil)
            return
        }

        let selection = ns.paragraphRange(for: selectedRange())
        var paragraphs: [NSRange] = []
        var location = selection.location
        while location < NSMaxRange(selection) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            guard NSMaxRange(paragraph) > location else { break }
            location = NSMaxRange(paragraph)
        }
        if paragraphs.isEmpty { paragraphs = [selection] }

        let considered = paragraphs.filter { paragraph in
            !ns.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !considered.isEmpty else { return }

        let allMarked = considered.allSatisfy { markerPrefixLength(of: ns.substring(with: $0), marker) != nil }

        // Compute all edits forward (numbering needs document order), apply
        // in reverse so earlier ranges stay valid.
        var edits: [(NSRange, String)] = []
        var ordinal = 1
        for paragraph in considered {
            let line = ns.substring(with: paragraph)
            if allMarked {
                let length = markerPrefixLength(of: line, marker) ?? 0
                edits.append((NSRange(location: paragraph.location, length: length), ""))
            } else {
                // Strip a competing list marker before adding the new one.
                var stripped = 0
                if marker != .quote {
                    stripped = markerPrefixLength(of: line, .bullet)
                        ?? markerPrefixLength(of: line, .numbered) ?? 0
                }
                let prefix: String
                switch marker {
                case .bullet: prefix = "- "
                case .numbered: prefix = "\(ordinal). "; ordinal += 1
                case .quote: prefix = "> "
                }
                edits.append((NSRange(location: paragraph.location, length: stripped), prefix))
            }
        }
        applyParagraphEdits(edits, spanning: selection)
    }

    /// Applies paragraph edits, computed in document order and not
    /// overlapping, then puts the user's selection back.
    ///
    /// Restoring it is the point. Each `replace` moves the insertion point to
    /// its own edit, so without this the selection collapses into whichever
    /// paragraph happened to be edited last: marking three lines as a list
    /// left only one line selected, and a second toggle then only saw that
    /// line. A caret is carried along by the text it sits in; a range keeps
    /// covering the same paragraphs.
    private func applyParagraphEdits(_ edits: [(NSRange, String)], spanning span: NSRange) {
        guard !edits.isEmpty else { return }
        let original = selectedRange()
        var totalDelta = 0
        var deltaBeforeCaret = 0
        for (range, replacement) in edits {
            let delta = (replacement as NSString).length - range.length
            totalDelta += delta
            if NSMaxRange(range) <= original.location { deltaBeforeCaret += delta }
        }
        // One change for the whole span, not one per paragraph: every change
        // re-renders the document, so toggling a list over 500 lines took
        // the best part of a minute. It also makes the toggle a single undo.
        let ns = string as NSString
        let first = edits[0].0.location
        var rebuilt = ""
        var cursor = first
        for (range, replacement) in edits {
            rebuilt += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            rebuilt += replacement
            cursor = NSMaxRange(range)
        }
        replace(NSRange(location: first, length: cursor - first), with: rebuilt, selecting: nil)
        let limit = (string as NSString).length
        if original.length == 0 {
            let caret = min(max(0, original.location + deltaBeforeCaret), limit)
            setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            let start = min(span.location, limit)
            let length = min(max(0, span.length + totalDelta), limit - start)
            setSelectedRange(NSRange(location: start, length: length))
        }
    }

    /// UTF-16 length of the marker prefix at the start of `line`, or nil.
    private func markerPrefixLength(of line: String, _ marker: ParagraphMarker) -> Int? {
        var index = line.startIndex
        var length = 0
        func consumeSpaces() {
            while index < line.endIndex, line[index] == " " {
                length += 1
                index = line.index(after: index)
            }
        }
        switch marker {
        case .bullet:
            guard index < line.endIndex, "-*+".contains(line[index]) else { return nil }
            length += 1
            index = line.index(after: index)
            guard index < line.endIndex, line[index] == " " else { return nil }
            consumeSpaces()
            return length
        case .numbered:
            var digits = 0
            // ASCII only: cmark takes "١." as prose, so it must be added
            // to, not stripped as a list marker already there.
            while index < line.endIndex, line[index].isASCII, line[index].isNumber {
                digits += 1
                length += String(line[index]).utf16.count
                index = line.index(after: index)
            }
            guard digits > 0, index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
            length += 1
            index = line.index(after: index)
            guard index < line.endIndex, line[index] == " " else { return nil }
            consumeSpaces()
            return length
        case .quote:
            guard index < line.endIndex, line[index] == ">" else { return nil }
            length += 1
            index = line.index(after: index)
            consumeSpaces()
            return length
        }
    }

    // MARK: Plumbing

    /// Undo-registering programmatic edit; routes through the same delegate
    /// notifications as typing so autosave and restyle both fire.
    private func replace(_ range: NSRange, with replacement: String, selecting: NSRange?) {
        guard shouldChangeText(in: range, replacementString: replacement),
              let storage = textStorage else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let selecting {
            setSelectedRange(selecting)
        }
    }
}
