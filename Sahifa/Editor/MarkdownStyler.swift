import AppKit
import Markdown

extension NSAttributedString.Key {
    /// Resolved base direction of the paragraph containing this character.
    /// Value is an Int: 0 = LTR, 1 = RTL. Used by BidiTextView to draw the
    /// per-paragraph direction affordance.
    static let sahifaDirection = NSAttributedString.Key("sahifa.direction")
}

struct EditorTheme: Equatable {
    var fontSize: CGFloat = 16
    var lineHeightMultiple: CGFloat = 1.4
}

/// Live in-place Markdown styling: the raw source stays visible and editable;
/// headings, emphasis, code, links etc. are styled via attributes, and every
/// paragraph gets an auto-detected base writing direction (dir="auto").
final class MarkdownStyler {

    var theme = EditorTheme()

    /// Focus mode: paragraph to keep at full strength while everything else
    /// dims. nil = no dimming. Dimming rides the normal diff-apply path
    /// (regular attributes, deterministic), so restyle stays a fixed point
    /// and layout is never invalidated — colors don't change metrics.
    /// (Not TextKit 2 rendering attributes: those fail to override the color
    /// of font-fixed Arabic runs.)
    var focusParagraph: NSRange?

    private var cachedText: String?
    private var cachedTheme: EditorTheme?
    private var cachedBase: NSAttributedString?

    func restyle(_ storage: NSTextStorage) {
        let text = storage.string
        let base: NSAttributedString
        if text == cachedText, theme == cachedTheme, let cachedBase {
            base = cachedBase
        } else {
            let styled = styledAttributedString(for: text)
            base = styled.copy() as! NSAttributedString
            cachedText = text
            cachedTheme = theme
            cachedBase = base
        }
        applyDiff(dimmedOutsideFocus(base), to: storage)
    }

    private func dimmedOutsideFocus(_ base: NSAttributedString) -> NSAttributedString {
        let full = NSRange(location: 0, length: base.length)
        guard let focusParagraph, full.length > 0 else { return base }
        let focus = NSIntersectionRange(focusParagraph, full)

        let dimmed = NSMutableAttributedString(attributedString: base)
        let dim = Brand.ink.withAlphaComponent(0.3)
        let head = NSRange(location: 0, length: focus.location)
        let tailStart = NSMaxRange(focus)
        let tail = NSRange(location: tailStart, length: full.length - tailStart)
        if head.length > 0 { dimmed.addAttribute(.foregroundColor, value: dim, range: head) }
        if tail.length > 0 { dimmed.addAttribute(.foregroundColor, value: dim, range: tail) }
        return dimmed
    }

    /// Builds the fully styled document off-screen. Kept separate from
    /// `restyle` so the result can be diffed against the live storage —
    /// applying only changed runs keeps TextKit 2 layout invalidation local
    /// to the edit, instead of re-laying-out (and visibly flashing) the
    /// whole document on every keystroke.
    func styledAttributedString(for text: String) -> NSMutableAttributedString {
        let ns = text as NSString
        let styled = NSMutableAttributedString(string: text, attributes: baseAttributes())
        applyParagraphDirections(styled, ns: ns)

        let document = Document(parsing: text)
        var walker = StyleWalker(storage: styled, ns: ns, map: SourceMap(text: text), theme: theme)
        walker.visit(document)
        // Match NSTextStorage's automatic font fixing (e.g. Arabic runs get
        // the cascade's Arabic face) so those runs don't diff as changed on
        // every restyle.
        styled.fixAttributes(in: NSRange(location: 0, length: ns.length))
        return styled
    }

    /// Applies `target`'s attributes to `storage`, touching only the runs
    /// whose attributes actually differ.
    private func applyDiff(_ target: NSAttributedString, to storage: NSTextStorage) {
        let length = storage.length
        guard target.length == length else {
            // Text changed under us; restyle is only called with matching text.
            storage.setAttributedString(target)
            return
        }
        guard length > 0 else { return }

        var edits: [(NSRange, [NSAttributedString.Key: Any])] = []
        var location = 0
        while location < length {
            let remainder = NSRange(location: location, length: length - location)
            var targetRun = NSRange()
            let targetAttrs = target.attributes(at: location, longestEffectiveRange: &targetRun, in: remainder)
            var storageRun = NSRange()
            let storageAttrs = storage.attributes(at: location, longestEffectiveRange: &storageRun, in: remainder)
            let runEnd = min(NSMaxRange(targetRun), NSMaxRange(storageRun))
            if !(targetAttrs as NSDictionary).isEqual(to: storageAttrs) {
                edits.append((NSRange(location: location, length: runEnd - location), targetAttrs))
            }
            location = runEnd
        }

        guard !edits.isEmpty else { return }
        storage.beginEditing()
        for (range, attrs) in edits {
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: FontLibrary.prose(size: theme.fontSize),
            .foregroundColor: Brand.ink,
        ]
    }

    // MARK: Per-paragraph auto direction

    /// Detects each paragraph's base direction from its first strong character
    /// and applies an explicit NSParagraphStyle. Direction-neutral paragraphs
    /// (blank lines, punctuation-only) inherit the previous paragraph's
    /// direction so the affordance doesn't flicker while typing.
    private func applyParagraphDirections(_ storage: NSMutableAttributedString, ns: NSString) {
        var location = 0
        var carried: BidiDirection = .leftToRight
        while location < ns.length {
            let paragraphRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraphRange.length > 0 else { break }
            let paragraph = ns.substring(with: paragraphRange)

            var direction = BidiDirection.firstStrong(in: paragraph)
            if direction == .neutral {
                direction = carried
            } else {
                carried = direction
            }
            let isRTL = direction == .rightToLeft

            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
            style.alignment = .natural
            style.lineHeightMultiple = theme.lineHeightMultiple
            style.paragraphSpacing = theme.fontSize * 0.4

            storage.addAttributes([
                .paragraphStyle: style,
                .sahifaDirection: isRTL ? 1 : 0,
            ], range: paragraphRange)

            location = NSMaxRange(paragraphRange)
        }
    }
}

// MARK: - Source location mapping

/// Maps swift-markdown SourceRanges (1-based line, 1-based UTF-8 byte column)
/// to NSString UTF-16 ranges. Correct for multi-byte Arabic text.
struct SourceMap {
    private let lines: [Substring]
    private let lineStartUTF16: [Int]

    init(text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var position = 0
        for line in lines {
            starts.append(position)
            position += line.utf16.count + 1
        }
        self.lines = lines
        self.lineStartUTF16 = starts
    }

    func utf16Offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lines.count else { return nil }
        let content = lines[line - 1]
        let start = lineStartUTF16[line - 1]
        let utf8 = content.utf8
        guard column >= 1,
              let index = utf8.index(utf8.startIndex, offsetBy: column - 1, limitedBy: utf8.endIndex)
        else {
            return start + content.utf16.count
        }
        return start + content[..<index].utf16.count
    }

    func nsRange(_ range: SourceRange) -> NSRange? {
        guard let lower = utf16Offset(line: range.lowerBound.line, column: range.lowerBound.column),
              let upper = utf16Offset(line: range.upperBound.line, column: range.upperBound.column),
              upper >= lower
        else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}

// MARK: - AST walker

private struct StyleWalker: MarkupWalker {
    let storage: NSMutableAttributedString
    let ns: NSString
    let map: SourceMap
    let theme: EditorTheme

    private func range(of markup: Markup) -> NSRange? {
        guard let sourceRange = markup.range, let r = map.nsRange(sourceRange),
              NSMaxRange(r) <= ns.length else { return nil }
        return r
    }

    // MARK: Block elements

    mutating func visitHeading(_ heading: Heading) {
        if let r = range(of: heading) {
            let scale: CGFloat
            switch heading.level {
            case 1: scale = 1.7
            case 2: scale = 1.45
            case 3: scale = 1.25
            case 4: scale = 1.1
            default: scale = 1.0
            }
            setProseFont(in: r, size: round(theme.fontSize * scale),
                         weight: heading.level <= 2 ? .bold : .semibold)
            styleHeadingMarkers(in: r)
        }
        descendInto(heading)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let r = range(of: codeBlock) else { return }
        storage.addAttributes([
            .font: FontLibrary.mono(size: theme.fontSize * 0.92),
            .backgroundColor: Brand.sand.withAlphaComponent(0.6),
        ], range: r)
        forceLTRParagraphs(in: r)
        // Fence lines (``` or ~~~) in Slate.
        enumerateLines(in: r) { lineRange, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                storage.addAttribute(.foregroundColor, value: Brand.slate, range: lineRange)
            }
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let r = range(of: blockQuote) {
            storage.addAttribute(.foregroundColor, value: Brand.slate, range: r)
            enumerateLines(in: r) { lineRange, line in
                var count = 0
                for ch in line {
                    if ch == ">" || ch == " " || ch == "\t" { count += 1 } else { break }
                }
                if count > 0 {
                    let markerRange = NSRange(location: lineRange.location, length: min(count, lineRange.length))
                    storage.addAttribute(.foregroundColor, value: Brand.sage, range: markerRange)
                }
            }
        }
        descendInto(blockQuote)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let r = range(of: listItem) {
            styleListMarker(in: r)
        }
        descendInto(listItem)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        if let r = range(of: thematicBreak) {
            storage.addAttribute(.foregroundColor, value: Brand.slate, range: r)
        }
    }

    // MARK: Inline elements

    mutating func visitStrong(_ strong: Strong) {
        if let r = range(of: strong) {
            addProseTraits(in: r, bold: true)
            styleDelimiters(in: r, count: 2)
        }
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        if let r = range(of: emphasis) {
            addProseTraits(in: r, italic: true)
            styleDelimiters(in: r, count: 1)
        }
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        if let r = range(of: strikethrough) {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: Brand.slate,
            ], range: r)
            styleDelimiters(in: r, count: 2)
        }
        descendInto(strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let r = range(of: inlineCode) else { return }
        storage.addAttributes([
            .font: FontLibrary.mono(size: theme.fontSize * 0.92),
            .backgroundColor: Brand.sand.withAlphaComponent(0.6),
        ], range: r)
        // Backtick delimiters in Slate.
        let text = ns.substring(with: r)
        let ticks = text.prefix(while: { $0 == "`" }).count
        if ticks > 0, r.length >= ticks * 2 {
            storage.addAttribute(.foregroundColor, value: Brand.slate,
                                 range: NSRange(location: r.location, length: ticks))
            storage.addAttribute(.foregroundColor, value: Brand.slate,
                                 range: NSRange(location: NSMaxRange(r) - ticks, length: ticks))
        }
    }

    mutating func visitLink(_ link: Link) {
        if let r = range(of: link) {
            storage.addAttribute(.foregroundColor, value: Brand.gold, range: r)
            // Dim the "](destination)" tail and the brackets.
            let text = ns.substring(with: r)
            if let tail = text.range(of: "](") {
                let tailStart = text.distance(from: text.startIndex, to: tail.lowerBound)
                let tailUTF16 = text[..<tail.lowerBound].utf16.count
                _ = tailStart
                storage.addAttribute(.foregroundColor, value: Brand.slate,
                                     range: NSRange(location: r.location + tailUTF16,
                                                    length: r.length - tailUTF16))
            }
            if text.hasPrefix("[") {
                storage.addAttribute(.foregroundColor, value: Brand.slate,
                                     range: NSRange(location: r.location, length: 1))
            }
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
        }
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        if let r = range(of: image) {
            storage.addAttribute(.foregroundColor, value: Brand.slate, range: r)
        }
        descendInto(image)
    }

    // MARK: Helpers

    private func setProseFont(in r: NSRange, size: CGFloat, weight: FontLibrary.ProseWeight) {
        storage.addAttribute(.font, value: FontLibrary.prose(size: size, weight: weight), range: r)
    }

    /// Adds bold/italic to whatever font is present, preserving size and the
    /// prose/mono family split — handles nesting like **bold _italic_** and
    /// emphasis inside headings.
    private func addProseTraits(in r: NSRange, bold: Bool = false, italic: Bool = false) {
        storage.enumerateAttribute(.font, in: r, options: []) { value, subRange, _ in
            guard let font = value as? NSFont else { return }
            let name = font.fontName
            let size = font.pointSize
            let currentBold = name.contains("Bold")
            let currentItalic = name.contains("Italic")
            let newFont: NSFont
            if name.contains("Mono") {
                newFont = FontLibrary.mono(size: size, bold: bold || currentBold, italic: italic || currentItalic)
            } else {
                let weight: FontLibrary.ProseWeight
                if bold || currentBold {
                    weight = .bold
                } else if name.contains("SmBld") {
                    weight = .semibold
                } else if name.contains("Medm") {
                    weight = .medium
                } else {
                    weight = .regular
                }
                newFont = FontLibrary.prose(size: size, weight: weight, italic: italic || currentItalic)
            }
            storage.addAttribute(.font, value: newFont, range: subRange)
        }
    }

    /// Colors the leading `#` run (plus trailing closing sequence, if any).
    private func styleHeadingMarkers(in r: NSRange) {
        let text = ns.substring(with: r)
        var count = 0
        for ch in text {
            if ch == "#" { count += 1 } else { break }
        }
        if count > 0 {
            storage.addAttribute(.foregroundColor, value: Brand.slate,
                                 range: NSRange(location: r.location, length: min(count, r.length)))
        }
    }

    /// Colors emphasis delimiters (`*`/`_`/`~`) at both ends of the range.
    private func styleDelimiters(in r: NSRange, count: Int) {
        guard r.length >= count * 2 else { return }
        let delimiters: Set<Character> = ["*", "_", "~"]
        let text = ns.substring(with: r)
        if let first = text.first, delimiters.contains(first) {
            storage.addAttribute(.foregroundColor, value: Brand.slate,
                                 range: NSRange(location: r.location, length: count))
            storage.addAttribute(.foregroundColor, value: Brand.slate,
                                 range: NSRange(location: NSMaxRange(r) - count, length: count))
        }
    }

    /// Colors the list bullet/number marker in Sage.
    private func styleListMarker(in r: NSRange) {
        let text = ns.substring(with: r)
        var utf16Length = 0
        var index = text.startIndex
        // Skip indentation.
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            utf16Length += 1
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return }
        let ch = text[index]
        if ch == "-" || ch == "*" || ch == "+" {
            utf16Length += 1
        } else if ch.isNumber {
            while index < text.endIndex, text[index].isNumber {
                utf16Length += 1
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "." || text[index] == ")" else { return }
            utf16Length += 1
        } else {
            return
        }
        storage.addAttribute(.foregroundColor, value: Brand.sage,
                             range: NSRange(location: r.location, length: min(utf16Length, r.length)))
    }

    /// Code is always LTR + left-aligned, regardless of surrounding content.
    private func forceLTRParagraphs(in r: NSRange) {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .leftToRight
        style.alignment = .left
        style.lineHeightMultiple = theme.lineHeightMultiple
        let paragraphRange = ns.paragraphRange(for: r)
        let clamped = NSIntersectionRange(paragraphRange, NSRange(location: 0, length: ns.length))
        storage.addAttributes([
            .paragraphStyle: style,
            .sahifaDirection: 0,
        ], range: clamped)
    }

    private func enumerateLines(in r: NSRange, _ body: (NSRange, String) -> Void) {
        var location = r.location
        let end = NSMaxRange(r)
        while location < end {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let clamped = NSIntersectionRange(lineRange, r)
            body(clamped, ns.substring(with: clamped))
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
    }
}
