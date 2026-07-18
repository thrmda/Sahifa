import AppKit

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
        let content = ns.substring(with: paragraphs)
        var body = content
        if body.isEmpty || body == "\n" { body = "\n" }
        else if !body.hasSuffix("\n") { body += "\n" }
        let fenced = "```\n" + body + "```\n"
        // Caret at the end of the wrapped content (just before its newline).
        let caret = paragraphs.location + 4 + (body as NSString).length - 1
        replace(paragraphs, with: fenced, selecting: NSRange(location: caret, length: 0))
    }

    @objc func sahifaInsertLink(_ sender: Any?) {
        insertLinkTemplate(prefix: "[")
    }

    @objc func sahifaInsertImage(_ sender: Any?) {
        insertLinkTemplate(prefix: "![")
    }

    @objc func sahifaInsertHorizontalRule(_ sender: Any?) {
        let sel = selectedRange()
        let text = "\n\n---\n\n"
        replace(sel, with: text,
                selecting: NSRange(location: sel.location + (text as NSString).length, length: 0))
    }

    @objc func sahifaInsertTable(_ sender: Any?) {
        let sel = selectedRange()
        let table = "\n\n| Column | Column |\n| --- | --- |\n|  |  |\n\n"
        // Land with the first "Column" selected, ready to type over.
        replace(sel, with: table,
                selecting: NSRange(location: sel.location + 4, length: 6))
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
        if sel.length >= 2 * d {
            let selected = ns.substring(with: sel)
            if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter) {
                let inner = String(selected.dropFirst(delimiter.count).dropLast(delimiter.count))
                replace(sel, with: inner,
                        selecting: NSRange(location: sel.location, length: (inner as NSString).length))
                return
            }
        }

        // Delimiters sit immediately outside the selection → remove them.
        if sel.location >= d, NSMaxRange(sel) + d <= ns.length,
           ns.substring(with: NSRange(location: sel.location - d, length: d)) == delimiter,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: d)) == delimiter {
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
        for paragraph in paragraphs.reversed() {
            let line = ns.substring(with: paragraph)

            var hashes = 0
            var index = line.startIndex
            while index < line.endIndex, line[index] == "#", hashes < 6 {
                hashes += 1
                index = line.index(after: index)
            }
            var prefixLength = 0
            if hashes > 0, index == line.endIndex || line[index] == " " || line[index] == "\n" {
                while index < line.endIndex, line[index] == " " {
                    index = line.index(after: index)
                }
                prefixLength = line[line.startIndex..<index].utf16.count
            }

            let existing = prefixLength > 0 ? hashes : 0
            let prefixRange = NSRange(location: paragraph.location, length: prefixLength)
            let replacement = existing == level ? "" : marker
            replace(prefixRange, with: replacement, selecting: nil)
        }
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
        for (range, replacement) in edits.reversed() {
            replace(range, with: replacement, selecting: nil)
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
            while index < line.endIndex, line[index].isNumber {
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
