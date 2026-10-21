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

    /// User-adjustable via `editorLineSpacing` (1.0–2.0).
    ///
    /// This is NOT the same quantity as the stylesheet's `line-height: 1.65`,
    /// and the two literals are not meant to match. NSParagraphStyle multiplies
    /// the *font's own* line height, while CSS multiplies the font size — so
    /// 1.4 here lands at 1.4 × 1.30 = 1.82em for Plex Sans against the
    /// preview's 1.65em, about 9% looser. Under Arabic the gap widens: the
    /// RTL factor below on Plex Sans Arabic's taller body gives 1.512 × 1.50 =
    /// 2.27em against the preview's 1.78em.
    ///
    /// Feeding this setting straight to the preview as a CSS line-height would
    /// therefore make the two disagree in a new way rather than align them; a
    /// faithful mapping has to fold in each script's natural line height. Left
    /// as is deliberately — the editor is the surface being typed in, and the
    /// preview reads as a page.
    var lineHeightMultiple: CGFloat = 1.4

    /// Extra leading for Arabic paragraphs, on top of the user's multiplier.
    ///
    /// Deliberately small. Plex Sans Arabic already carries a taller
    /// ascent/descent than Plex Sans (151 vs 131 per 100pt), so Arabic lines
    /// come out ~15% taller before anything is added here; a big jump would
    /// leave Arabic paragraphs visibly airier than the Latin ones beside them.
    /// This is only the bit of room that stacked diacritics and the descenders
    /// of ج ح خ need to clear the line below.
    static let rtlLineHeightFactor: CGFloat = 1.08

    func lineHeightMultiple(rtl: Bool) -> CGFloat {
        rtl ? lineHeightMultiple * Self.rtlLineHeightFactor : lineHeightMultiple
    }
}

/// Live in-place Markdown styling: the raw source stays visible and editable;
/// headings, emphasis, code, links etc. are styled via attributes, and every
/// paragraph gets an auto-detected base writing direction (dir="auto").
final class MarkdownStyler {

    var theme = EditorTheme()

    /// Off for CSV and TSV, whose raw text is shown plain: a `#` or `*` in a
    /// cell is data, not a heading or emphasis. Each paragraph still gets its
    /// own direction.
    var parsesMarkdown = true {
        didSet { if parsesMarkdown != oldValue { cachedText = nil } }
    }

    /// Focus mode: paragraph to keep at full strength while everything else
    /// dims. nil = no dimming. Dimming rides the normal diff-apply path
    /// (regular attributes, deterministic), so restyle stays a fixed point
    /// and layout is never invalidated — colors don't change metrics.
    /// (Not TextKit 2 rendering attributes: those fail to override the color
    /// of font-fixed Arabic runs.)
    var focusParagraph: NSRange?

    private var cachedText: NSString?
    private var cachedTheme: EditorTheme?
    /// The styled document for `cachedText`, before focus dimming. Patched
    /// in place by `restyleEdited` rather than rebuilt.
    private var cachedBase: NSMutableAttributedString?
    /// Top-level Markdown blocks of `cachedText`, to tell which ones an edit
    /// actually changed.
    private var cachedBlocks: [Block] = []
    /// The focus paragraph whose dimming the storage currently carries.
    private var appliedFocus: NSRange?

    /// Where the observed storage's text has changed since the last restyle,
    /// in its current text, and by how much its length changed. Taken from
    /// the storage itself: comparing old and new text can't say which of
    /// two identical neighbours was typed, and guessing wrong left a newly
    /// typed newline unstyled.
    private var pendingEdit: NSRange?
    private var pendingDelta = 0
    /// Whether the storage has changed since the last restyle.
    var hasPendingEdit: Bool { pendingEdit != nil }
    private var editObserver: NSObjectProtocol?

    deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
    }

    /// Starts recording `storage`'s text edits for `restyleEdited`.
    func observeEdits(of storage: NSTextStorage) {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { [weak self, weak storage] _ in
            guard let self, let storage, storage.editedMask.contains(.editedCharacters) else { return }
            self.recordEdit(storage.editedRange, changeInLength: storage.changeInLength)
        }
    }

    private func recordEdit(_ edited: NSRange, changeInLength delta: Int) {
        if let pending = pendingEdit {
            // Carry the earlier edit into the text as it is now.
            let replaced = NSRange(location: edited.location, length: edited.length - delta)
            pendingEdit = NSUnionRange(Self.map(pending, through: (replaced, edited.length)), edited)
        } else {
            pendingEdit = edited
        }
        pendingDelta += delta
    }

    /// A top-level block: where it is and what kind it is. Same range, same
    /// kind and same text means it styles the same.
    private struct Block: Equatable {
        var range: NSRange
        var kind: ObjectIdentifier
    }

    /// Rebuilds the whole document's styling and applies whatever differs.
    /// For a new document, a new theme, or text replaced from outside.
    func restyle(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        // Literal comparison: Swift's == calls canonically equivalent strings
        // equal, and reusing a result styled for the other form (a different
        // UTF-16 length) wrote that older text back over the edit.
        let cached = cachedText.map { text.isEqual(to: $0) } == true && theme == cachedTheme && cachedBase != nil
        if !cached {
            let (styled, blocks) = buildStyled(for: text as String)
            cachedText = text.copy() as? NSString
            cachedTheme = theme
            cachedBase = styled
            cachedBlocks = blocks
        }
        pendingEdit = nil
        pendingDelta = 0
        lastRestyledLength = storage.length
        applyDiff(in: [NSRange(location: 0, length: storage.length)], to: storage)
    }

    /// Restyles after the storage's own text was edited, touching only the
    /// blocks the edit changed. Everything outside the edit must still carry
    /// the styling the last restyle gave it, which holds for typing, undo and
    /// the formatting commands but not for text set from outside: use
    /// `restyle` for that. Needs `observeEdits(of:)` on the same storage.
    ///
    /// On a 90 KB document this is the difference between about 200 ms and a
    /// few milliseconds per keystroke: rebuilding styles everything, and
    /// diffing everything compares every run.
    func restyleEdited(_ storage: NSTextStorage) {
        guard let cachedText, let cachedBase, theme == cachedTheme,
              cachedBase.length == cachedText.length
        else { return restyle(storage) }

        let text = storage.string as NSString
        var regions: [NSRange] = []
        var oldFocus = appliedFocus

        if let pending = pendingEdit {
            let edit = (range: NSRange(location: pending.location, length: pending.length - pendingDelta),
                        newLength: pending.length)
            pendingEdit = nil
            pendingDelta = 0
            guard edit.range.length >= 0, NSMaxRange(edit.range) <= cachedText.length,
                  let dirty = patchBase(cachedBase, from: cachedText, to: text, edit: edit)
            else { return restyle(storage) }
            regions.append(dirty)
            lastRestyledLength = dirty.length
            oldFocus = oldFocus.map { Self.map($0, through: edit) }
        } else if !text.isEqual(to: cachedText) {
            // Changed without our seeing it.
            return restyle(storage)
        }

        if (oldFocus == nil) != (focusParagraph == nil) {
            // Focus mode switched on or off: everything dims or undims.
            regions = [NSRange(location: 0, length: text.length)]
        } else if oldFocus != focusParagraph {
            regions += [oldFocus, focusParagraph].compactMap { $0 }
        }
        applyDiff(in: regions, to: storage)
    }

    /// How many times the whole document has been styled from scratch. For
    /// tests: typing should leave it alone.
    private(set) var fullRebuilds = 0
    /// How much of the document the last restyle went over. For tests.
    private(set) var lastRestyledLength = 0

    /// A line that may begin a link reference definition, at the top level
    /// or inside a quote or list, capturing its label (which may run over
    /// a line break). Any "]:" used to count, so `arr[i]:` in a code block
    /// put every keystroke on the slow path.
    private static let definitionCandidate = try! NSRegularExpression(
        pattern: #"(?m)^[ \t>*+\-\d.)]*\[([^\]]{1,999})\]:"#)

    /// Blocks whose leading lines can be link reference definitions: cmark
    /// strips them from the start of a paragraph, or of the paragraph a
    /// setext underline turns into a heading, yet reports the block as
    /// beginning where they began.
    private static let strippingKinds: Set<ObjectIdentifier> = [
        ObjectIdentifier(Paragraph.self), ObjectIdentifier(Heading.self),
    ]
    /// Other blocks that can't hold one: a `[x]:` line inside is code or data.
    private static let leafKinds: Set<ObjectIdentifier> = [
        ObjectIdentifier(CodeBlock.self), ObjectIdentifier(HTMLBlock.self),
        ObjectIdentifier(ThematicBreak.self), ObjectIdentifier(Table.self),
    ]

    /// The link reference definitions within `region` of `text`, given its
    /// top-level blocks in order: each label with the span of text that
    /// defines it. A definition leaves no block behind, and nothing but
    /// blank lines does, so a candidate line between two blocks is one; at
    /// the start of a paragraph it is one if cmark stripped it. nil when a
    /// candidate sits inside a quote or list, where only a full parse can
    /// tell.
    private static func definitions(in text: NSString, within region: NSRange,
                                    blocks: [Block]) -> [(label: String, span: NSRange)]? {
        var found: [(label: String, span: NSRange)] = []
        var index = 0
        for match in definitionCandidate.matches(in: text as String, range: region) {
            let at = match.range.location
            let label = text.substring(with: match.range(at: 1))
            while index < blocks.count, NSMaxRange(blocks[index].range) <= at { index += 1 }
            if index < blocks.count, blocks[index].range.location <= at {
                let block = blocks[index]
                if leafKinds.contains(block.kind) { continue }
                guard strippingKinds.contains(block.kind) else { return nil }
                guard let stripped = strippedDefinitions(of: text.substring(with: block.range) as NSString,
                                                         holding: at - block.range.location) else { continue }
                found.append((label, NSRange(location: block.range.location, length: stripped)))
                continue
            }
            let start = index > 0 ? NSMaxRange(blocks[index - 1].range) : 0
            let end = index < blocks.count ? blocks[index].range.location : text.length
            found.append((label, NSRange(location: start, length: end - start)))
        }
        return found
    }

    /// The length of the definitions cmark stripped from the start of a
    /// paragraph's text, when the line at `offset` is among them, else nil.
    /// cmark takes definitions from the start for as long as they parse,
    /// and a text that is nothing but definitions parses to nothing, so the
    /// longest prefix of lines that parses to nothing is what it stripped.
    /// A definition runs over three lines at most (label, destination,
    /// title), so a few lines past `offset` settle it.
    private static func strippedDefinitions(of text: NSString, holding offset: Int) -> Int? {
        var stripped = 0
        var lineEnd = 0
        var line = 0
        var target: Int?
        while lineEnd < text.length, target.map({ line < $0 + 3 }) ?? true {
            let range = text.lineRange(for: NSRange(location: lineEnd, length: 0))
            if target == nil, NSLocationInRange(offset, range) { target = line }
            lineEnd = NSMaxRange(range)
            line += 1
            if Document(parsing: text.substring(to: lineEnd)).childCount == 0 { stripped = lineEnd }
        }
        guard let target, target < line, stripped > offset else { return nil }
        return stripped
    }

    /// Builds the styled document and its top-level blocks from scratch.
    private func buildStyled(for text: String) -> (NSMutableAttributedString, [Block]) {
        fullRebuilds += 1
        let ns = text as NSString
        let styled = NSMutableAttributedString(string: text, attributes: baseAttributes())
        applyParagraphDirections(styled, ns: ns, in: NSRange(location: 0, length: ns.length),
                                 carried: .leftToRight)
        var blocks: [Block] = []
        if parsesMarkdown {
            let parsed = Self.topLevelBlocks(of: Document(parsing: text), map: SourceMap(text: text),
                                             length: ns.length)
            for case let (block, (markup, map)?) in parsed {
                style(markup, in: block, storage: styled, ns: ns, map: map)
            }
            blocks = parsed.map(\.block)
        }
        // Match NSTextStorage's automatic font fixing (e.g. Arabic runs get
        // the cascade's Arabic face) so those runs don't diff as changed on
        // every restyle.
        styled.fixAttributes(in: NSRange(location: 0, length: ns.length))
        return (styled, blocks)
    }

    /// Builds the fully styled document off-screen. Kept separate from
    /// `restyle` so the result can be diffed against the live storage —
    /// applying only changed runs keeps TextKit 2 layout invalidation local
    /// to the edit, instead of re-laying-out (and visibly flashing) the
    /// whole document on every keystroke.
    func styledAttributedString(for text: String) -> NSMutableAttributedString {
        buildStyled(for: text).0
    }

    // MARK: Restyling only what an edit changed

    /// Carries a range in the old text across an edit into the new text.
    private static func map(_ range: NSRange, through edit: (range: NSRange, newLength: Int)) -> NSRange {
        let delta = edit.newLength - edit.range.length
        if NSMaxRange(range) <= edit.range.location { return range }
        if range.location >= NSMaxRange(edit.range) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        let start = min(range.location, edit.range.location)
        let end = max(NSMaxRange(range) + delta, edit.range.location + edit.newLength)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Applies the edit to `base` and restyles the part of it that changed.
    /// Returns that part, in the new text, or nil when the edit could reach
    /// beyond the blocks it touched and only a full rebuild is safe.
    private func patchBase(_ base: NSMutableAttributedString, from old: NSString, to new: NSString,
                           edit: (range: NSRange, newLength: Int)) -> NSRange? {
        let delta = edit.newLength - edit.range.length

        // Blocks kept from the last parse have no markup to walk, so the
        // parse window widens until every block to restyle is inside it.
        var reach = 1
        var blocks: [ParsedBlock]
        var dirty: NSRange
        while true {
            var complete = true
            if parsesMarkdown {
                (blocks, complete) = parsedBlocks(of: new, edit: edit, reach: reach)
            } else {
                blocks = []
            }
            let range = changedRange(in: new, blocks: blocks.map { $0.block }, edit: edit)
            dirty = range
            let unparsed = blocks.contains { block in
                block.parsed == nil && NSIntersectionRange(block.block.range, range).length > 0
            }
            guard unparsed else { break }
            if complete { return nil }
            reach *= 4
        }

        // A link reference definition is read by every link that names it,
        // wherever that is: an edit that changes which labels are defined
        // can change a link anywhere, so only a full rebuild is safe then.
        // Typing in a definition's URL defines the same labels, and that
        // used to rebuild everything on every keystroke.
        if parsesMarkdown {
            let oldDirty = NSRange(location: dirty.location, length: dirty.length - delta)
            guard let was = Self.definitions(in: old, within: oldDirty, blocks: cachedBlocks),
                  let now = Self.definitions(in: new, within: dirty, blocks: blocks.map(\.block)),
                  was.map(\.label) == now.map(\.label)
            else { return nil }
        }

        base.replaceCharacters(in: edit.range, with: new.substring(with: NSRange(location: edit.range.location,
                                                                                  length: edit.newLength)))
        // The recorded edit has to account for the whole change.
        guard (base.string as NSString).isEqual(to: new) else { return nil }
        base.setAttributes(baseAttributes(), range: dirty)
        applyParagraphDirections(base, ns: new, in: dirty, carried: carriedDirection(before: dirty.location, in: new))
        for case let (block, (markup, map)?) in blocks where NSIntersectionRange(block.range, dirty).length > 0 {
            style(markup, in: block, storage: base, ns: new, map: map)
        }
        base.fixAttributes(in: dirty)

        cachedText = new.copy() as? NSString
        cachedBlocks = blocks.map(\.block)
        return dirty
    }

    /// The part of the new text to restyle: everything between the blocks
    /// before and after the edit that came through unchanged, which style
    /// exactly as they did.
    private func changedRange(in new: NSString, blocks: [Block],
                              edit: (range: NSRange, newLength: Int)) -> NSRange {
        let editEnd = edit.range.location + edit.newLength
        let delta = edit.newLength - edit.range.length
        let oldBlocks = cachedBlocks
        var first = 0
        while first < min(oldBlocks.count, blocks.count), oldBlocks[first] == blocks[first],
              NSMaxRange(blocks[first].range) <= edit.range.location {
            first += 1
        }
        var lastOld = oldBlocks.count - 1, lastNew = blocks.count - 1
        while lastOld >= first, lastNew >= first {
            var shifted = oldBlocks[lastOld]
            shifted.range.location += delta
            guard shifted == blocks[lastNew], shifted.range.location >= editEnd,
                  oldBlocks[lastOld].range.location >= NSMaxRange(edit.range) else { break }
            lastOld -= 1
            lastNew -= 1
        }
        // One unchanged block either side is restyled too. cmark's source
        // positions can be off by a character around CR line endings, so a
        // block can keep its range and kind and still parse differently
        // when its neighbour changes.
        var start = first > 1 ? NSMaxRange(blocks[first - 2].range) : 0
        var end = lastNew + 2 < blocks.count ? blocks[lastNew + 2].range.location : new.length
        if blocks.isEmpty {
            // No blocks at all (a CSV, whose text is shown plain): only the
            // paragraphs around the edit. "Everything between the unchanged
            // blocks" was the whole file, on every keystroke.
            // Through the paragraph the edit ends in: a line break typed
            // mid-paragraph makes a new one after it, with its own direction.
            start = edit.range.location
            end = NSMaxRange(new.paragraphRange(for: NSRange(location: editEnd, length: 0)))
        }
        var dirty = NSRange(location: min(start, edit.range.location),
                            length: max(end, editEnd) - min(start, edit.range.location))

        // Grow to whole paragraphs (each carries one direction), on through
        // the direction-neutral paragraphs after it that inherit that
        // direction, and to whole blocks.
        while true {
            var grown = new.paragraphRange(for: dirty)
            while NSMaxRange(grown) < new.length {
                let next = new.paragraphRange(for: NSRange(location: NSMaxRange(grown), length: 0))
                guard BidiDirection.firstStrong(in: new.substring(with: next)) == .neutral else { break }
                grown = NSUnionRange(grown, next)
            }
            for block in blocks where NSIntersectionRange(block.range, grown).length > 0
                || (block.range.length == 0 && NSLocationInRange(block.range.location, grown)) {
                grown = NSUnionRange(grown, block.range)
            }
            if grown == dirty { break }
            dirty = grown
        }
        return dirty
    }

    /// Styles one top-level block, and nothing outside it: cmark gives a
    /// fence left open inside a quote or list item a range that runs on
    /// over the next line, which styled the paragraph after it as code.
    private func style(_ markup: Markup, in block: Block, storage: NSMutableAttributedString,
                       ns: NSString, map: SourceMap) {
        var walker = StyleWalker(storage: storage, ns: ns, map: map, theme: theme, limit: block.range)
        walker.visit(markup)
    }

    private typealias ParsedBlock = (block: Block, parsed: (markup: Markup, map: SourceMap)?)

    /// Each block ends where the next begins. cmark can give a block a range
    /// that runs into the next one (a setext heading over CRLF lines does),
    /// and the overlap styled the next block as part of it.
    private static func topLevelBlocks(of document: Document, map: SourceMap,
                                       length: Int) -> [ParsedBlock] {
        var blocks: [ParsedBlock] = document.children.compactMap { child in
            guard let source = child.range, let range = map.nsRange(source), NSMaxRange(range) <= length
            else { return nil }
            return (Block(range: range, kind: ObjectIdentifier(type(of: child))), (child, map))
        }
        for i in blocks.indices.dropLast() {
            let next = blocks[i + 1].block.range.location
            let range = blocks[i].block.range
            if NSMaxRange(range) > next {
                blocks[i].block.range.length = max(0, next - range.location)
            }
        }
        return blocks
    }

    /// The new text's top-level blocks. Parsing the whole document costs
    /// about 20 ms at 90 KB, so only a window around the edit is parsed,
    /// from the block before it to where the blocks after it line up with
    /// the last parse again; the rest are carried over from that parse,
    /// without markup.
    private func parsedBlocks(of new: NSString, edit: (range: NSRange, newLength: Int),
                              reach: Int) -> (blocks: [ParsedBlock], complete: Bool) {
        let old = cachedBlocks
        let delta = edit.newLength - edit.range.length
        func shifted(_ block: Block) -> Block {
            Block(range: NSRange(location: block.range.location + delta, length: block.range.length),
                  kind: block.kind)
        }
        func parseWhole() -> (blocks: [ParsedBlock], complete: Bool) {
            let map = SourceMap(text: new as String)
            return (Self.topLevelBlocks(of: Document(parsing: new as String), map: map, length: new.length), true)
        }

        // A link reference definition counts wherever it is, so the ones
        // outside the window are parsed along with it, each on the side of
        // the window it sits on: a window that left them out would parse
        // its links differently, and a fence left open in the window runs
        // over whatever follows it, as it does in the document. Blocks
        // after the edit sit `delta` further along in the new text.
        let current = old.map { $0.range.location >= NSMaxRange(edit.range) ? shifted($0) : $0 }
        func parse(_ window: NSRange) -> [ParsedBlock]? {
            let windowEnd = NSMaxRange(window)
            var sides: [String] = []
            for region in [NSRange(location: 0, length: window.location),
                           NSRange(location: windowEnd, length: new.length - windowEnd)] {
                var spans: [NSRange] = []
                if region.length > 0 {
                    guard let outside = Self.definitions(in: new, within: region, blocks: current) else { return nil }
                    for definition in outside {
                        let span = NSIntersectionRange(definition.span, region)
                        if spans.last != span { spans.append(span) }
                    }
                }
                sides.append(spans.map { new.substring(with: $0) }.joined(separator: "\n\n"))
            }
            let prefix = sides[0].isEmpty ? "" : sides[0] + "\n\n"
            let suffix = sides[1].isEmpty ? "" : "\n\n" + sides[1]
            let text = prefix + new.substring(with: window) + suffix
            let start = window.location - (prefix as NSString).length
            let map = SourceMap(text: text, offset: start)
            let blocks = Self.topLevelBlocks(of: Document(parsing: text), map: map,
                                             length: start + (text as NSString).length)
            guard !prefix.isEmpty || !suffix.isEmpty else { return blocks }
            // The definitions leave no blocks of their own; a block that
            // ran on into them ends with the window, as it would have.
            return blocks.compactMap { block in
                guard block.block.range.location >= window.location, block.block.range.location < windowEnd
                    || block.block.range.length == 0 && block.block.range.location == windowEnd else { return nil }
                var clamped = block
                clamped.block.range.length = min(clamped.block.range.length, windowEnd - clamped.block.range.location)
                return clamped
            }
        }

        // The block just before the edit can run on into it (a paragraph
        // that turns into a list item joins the list above), so the window
        // starts `reach` blocks before that one, and ends at least `reach`
        // after the edit. Windows start at line starts, where cmark does.
        let before = old.lastIndex { NSMaxRange($0.range) <= edit.range.location }
        let kept = before.map { max(0, $0 - reach) } ?? 0
        let windowStart = before == nil ? 0
            : new.lineRange(for: NSRange(location: old[kept].range.location, length: 0)).location
        let after = old.firstIndex { $0.range.location >= NSMaxRange(edit.range) } ?? old.count

        var span = reach + 1
        while true {
            let end = min(after + span, old.count)
            let windowEnd = end < old.count
                ? new.lineRange(for: NSRange(location: old[end].range.location + delta, length: 0)).location
                : new.length
            guard let window = parse(NSRange(location: windowStart, length: windowEnd - windowStart))
            else { return parseWhole() }
            // Back in step: the window's last block is the one the last parse
            // had there, so everything from there on parses as it did.
            if end == old.count || (end > after && window.last?.block == shifted(old[end - 1])) {
                let blocks: [ParsedBlock] = old[..<kept].map { ($0, nil) }
                    + window
                    + old[end...].map { (shifted($0), nil) }
                return (blocks, windowStart == 0 && end == old.count)
            }
            span *= 2
        }
    }

    /// The direction a neutral paragraph starting at `location` inherits:
    /// that of the nearest paragraph before it with a strong character.
    private func carriedDirection(before location: Int, in ns: NSString) -> BidiDirection {
        var end = location
        while end > 0 {
            let paragraph = ns.paragraphRange(for: NSRange(location: end - 1, length: 0))
            let direction = BidiDirection.firstStrong(in: ns.substring(with: paragraph))
            if direction != .neutral { return direction }
            end = paragraph.location
        }
        return .leftToRight
    }

    /// Applies the base attributes, dimmed outside the focus paragraph, to
    /// `storage` within `regions`, touching only the runs that differ.
    private func applyDiff(in regions: [NSRange], to storage: NSTextStorage) {
        guard let base = cachedBase else { return }
        let length = storage.length
        guard base.length == length else {
            // Text changed under us; restyle is only called with matching text.
            storage.setAttributedString(base)
            appliedFocus = nil
            return
        }

        let dim = Brand.ink.withAlphaComponent(0.3)
        var edits: [(NSRange, [NSAttributedString.Key: Any])] = []
        for region in Self.merged(regions, within: length) {
            let target = NSMutableAttributedString(attributedString: base.attributedSubstring(from: region))
            if let focusParagraph {
                let focus = NSIntersectionRange(focusParagraph, NSRange(location: 0, length: length))
                let head = NSIntersectionRange(region, NSRange(location: 0, length: focus.location))
                let tail = NSIntersectionRange(region, NSRange(location: NSMaxRange(focus),
                                                               length: length - NSMaxRange(focus)))
                for part in [head, tail] where part.length > 0 {
                    target.addAttribute(.foregroundColor, value: dim,
                                        range: NSRange(location: part.location - region.location, length: part.length))
                }
            }
            var offset = 0
            while offset < region.length {
                let remainder = NSRange(location: offset, length: region.length - offset)
                var targetRun = NSRange()
                let targetAttrs = target.attributes(at: offset, longestEffectiveRange: &targetRun, in: remainder)
                var storageRun = NSRange()
                let storageAttrs = storage.attributes(at: region.location + offset, longestEffectiveRange: &storageRun,
                                                      in: NSRange(location: region.location + offset,
                                                                  length: region.length - offset))
                let runEnd = min(NSMaxRange(targetRun), NSMaxRange(storageRun) - region.location)
                if !(targetAttrs as NSDictionary).isEqual(to: storageAttrs) {
                    edits.append((NSRange(location: region.location + offset, length: runEnd - offset), targetAttrs))
                }
                offset = runEnd
            }
        }
        appliedFocus = focusParagraph

        guard !edits.isEmpty else { return }
        storage.beginEditing()
        for (range, attrs) in edits {
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()
    }

    /// Sorted, clamped, with overlapping and touching ranges joined.
    private static func merged(_ ranges: [NSRange], within length: Int) -> [NSRange] {
        let clamped = ranges.map { NSIntersectionRange($0, NSRange(location: 0, length: length)) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in clamped {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
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
    private func applyParagraphDirections(_ storage: NSMutableAttributedString, ns: NSString,
                                          in range: NSRange, carried initial: BidiDirection) {
        var location = range.location
        var carried = initial
        while location < NSMaxRange(range) {
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
            style.lineHeightMultiple = theme.lineHeightMultiple(rtl: isRTL)
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
    /// UTF-16 offset for each UTF-8 offset of a line that isn't plain ASCII,
    /// made the first time the line is asked about. Walking the line's
    /// prefix for every node made one long Arabic paragraph quadratic: nine
    /// seconds a keystroke at 90 KB.
    private final class Tables { var byLine: [Int: [Int]] = [:] }
    private let tables = Tables()

    /// Lines end where cmark ends them: at LF, CRLF or a lone CR. Splitting
    /// on the Character "\n" missed CRLF entirely (Swift treats "\r\n" as
    /// one Character, not equal to "\n"), so a Windows file was one long
    /// line and nothing after its first line was styled.
    /// `offset` is where `text` starts in the document, for a parse of
    /// part of it.
    init(text: String, offset: Int = 0) {
        var lines: [Substring] = []
        var starts: [Int] = []
        let units = text.utf16
        var lineStart = units.startIndex
        var lineStartOffset = offset
        var offset = offset
        var index = units.startIndex
        while index < units.endIndex {
            let unit = units[index]
            guard unit == 10 || unit == 13 else {
                index = units.index(after: index)
                offset += 1
                continue
            }
            lines.append(text[lineStart..<index])
            starts.append(lineStartOffset)
            var next = units.index(after: index)
            offset += 1
            if unit == 13, next < units.endIndex, units[next] == 10 {
                next = units.index(after: next)
                offset += 1
            }
            index = next
            lineStart = next
            lineStartOffset = offset
        }
        lines.append(text[lineStart..<units.endIndex])
        starts.append(lineStartOffset)
        self.lines = lines
        self.lineStartUTF16 = starts
    }

    func utf16Offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lines.count else { return nil }
        let content = lines[line - 1]
        let start = lineStartUTF16[line - 1]
        let utf8Count = content.utf8.count
        let utf16Count = content.utf16.count
        let offset = max(0, column - 1)
        guard offset < utf8Count else { return start + utf16Count }
        // All ASCII: a byte is a unit.
        if utf8Count == utf16Count { return start + offset }
        if let table = tables.byLine[line] { return start + table[offset] }
        var table = [Int](repeating: 0, count: utf8Count + 1)
        var utf8Offset = 0, utf16Offset = 0
        for scalar in content.unicodeScalars {
            let width = scalar.utf8.count
            for i in 0..<width { table[utf8Offset + i] = utf16Offset }
            utf8Offset += width
            utf16Offset += scalar.utf16.count
        }
        table[utf8Count] = utf16Offset
        tables.byLine[line] = table
        return start + table[offset]
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
    /// The top-level block being styled; nothing outside it is touched.
    let limit: NSRange

    private func range(of markup: Markup) -> NSRange? {
        guard let sourceRange = markup.range, let r = map.nsRange(sourceRange),
              NSMaxRange(r) <= ns.length else { return nil }
        let start = max(r.location, limit.location), end = min(NSMaxRange(r), NSMaxRange(limit))
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Block elements

    mutating func visitHeading(_ heading: Heading) {
        if let r = range(of: heading) {
            // Shared with the export CSS (Theme.Typography.headingScale) so a
            // heading is the same size in the editor, preview and PDF.
            let scale = Typography.headingScale(level: heading.level)
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
            .backgroundColor: Brand.panel.withAlphaComponent(0.6),
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
            .backgroundColor: Brand.panel.withAlphaComponent(0.6),
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
        } else if ch.isASCII, ch.isNumber {
            while index < text.endIndex, text[index].isASCII, text[index].isNumber {
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
