import Foundation
import Markdown

/// Markdown → HTML with Sahifa's bidi rules baked in: every block-level
/// element carries `dir="auto"` so each paragraph, heading, list item and
/// quote resolves its own direction from its first strong character — while
/// code (block and inline) is pinned LTR. Mirrors exactly what the editor
/// does with per-paragraph writing direction.
enum MarkdownHTMLRenderer {

    /// Body-only fragment (used by the live preview's incremental updates).
    static func body(from markdown: String) -> String {
        var visitor = HTMLVisitor()
        return visitor.visit(Document(parsing: markdown, options: [.parseBlockDirectives]))
    }

    /// Complete self-contained page (used for HTML export and PDF rendering).
    static func standalone(title: String, markdown: String) -> String {
        page(title: title, bodyContent: body(from: markdown), script: "")
    }

    /// Empty page shell with a JS `sahifaRender` hook. The live preview loads
    /// this once and then swaps content in place, so the WebView keeps its
    /// scroll position across edits.
    static func previewShell() -> String {
        page(title: "Preview",
             bodyContent: "",
             script: """
             <script>
             function sahifaRender(html, resetScroll) {
               document.getElementById("sahifa-content").innerHTML = html;
               if (resetScroll) {
                 // New document in the same WebView: back to the top, without
                 // echoing the jump to the editor as a user scroll.
                 __suppressScroll = true;
                 window.scrollTo(0, 0);
                 requestAnimationFrame(function () {
                   requestAnimationFrame(function () { __suppressScroll = false; });
                 });
               }
             }
             // Scroll sync: Swift calls sahifaScrollTo() to follow the editor;
             // user scrolls post their fraction back. __suppressScroll stops the
             // programmatic scroll from echoing straight back as a user scroll.
             var __suppressScroll = false;
             function sahifaScrollTo(fraction) {
               __suppressScroll = true;
               var max = document.documentElement.scrollHeight - window.innerHeight;
               window.scrollTo(0, max > 0 ? max * fraction : 0);
               requestAnimationFrame(function () {
                 requestAnimationFrame(function () { __suppressScroll = false; });
               });
             }
             window.addEventListener("scroll", function () {
               if (__suppressScroll) return;
               var handler = window.webkit && window.webkit.messageHandlers &&
                             window.webkit.messageHandlers.sahifaScroll;
               if (!handler) return;
               var max = document.documentElement.scrollHeight - window.innerHeight;
               handler.postMessage(max > 0 ? window.scrollY / max : 0);
             }, { passive: true });
             </script>
             """)
    }

    private static func page(title: String, bodyContent: String, script: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>\(fontFaceCSS)\(css)</style>
        </head>
        <body>
        <main id="sahifa-content">
        \(bodyContent)
        </main>
        \(script)
        </body>
        </html>
        """
    }

    // MARK: Embedded fonts

    /// The Plex faces the CSS font stacks actually reference. WKWebView (and any
    /// standalone exported file) can't see process-registered fonts — they'd
    /// silently fall back to system faces unless Plex happens to be installed
    /// system-wide — so we inline the OTFs as base64 `data:` URIs. Kept to the
    /// weights/styles the stylesheet uses (Sans 400/700 + italics, Arabic
    /// 400/700, Mono 400/700 + italic) to keep exported files from bloating.
    private struct EmbeddedFace {
        let file: String       // bundle filename, without extension
        let family: String     // must match a family in the CSS font stacks
        let weight: Int
        let italic: Bool
    }

    private static let embeddedFaces: [EmbeddedFace] = [
        EmbeddedFace(file: "IBMPlexSans-Regular",       family: "IBM Plex Sans",        weight: 400, italic: false),
        EmbeddedFace(file: "IBMPlexSans-Bold",          family: "IBM Plex Sans",        weight: 700, italic: false),
        EmbeddedFace(file: "IBMPlexSans-Italic",        family: "IBM Plex Sans",        weight: 400, italic: true),
        EmbeddedFace(file: "IBMPlexSans-BoldItalic",    family: "IBM Plex Sans",        weight: 700, italic: true),
        EmbeddedFace(file: "IBMPlexSansArabic-Regular", family: "IBM Plex Sans Arabic", weight: 400, italic: false),
        EmbeddedFace(file: "IBMPlexSansArabic-Bold",    family: "IBM Plex Sans Arabic", weight: 700, italic: false),
        EmbeddedFace(file: "IBMPlexMono-Regular",       family: "IBM Plex Mono",        weight: 400, italic: false),
        EmbeddedFace(file: "IBMPlexMono-Bold",          family: "IBM Plex Mono",        weight: 700, italic: false),
        EmbeddedFace(file: "IBMPlexMono-Italic",        family: "IBM Plex Mono",        weight: 400, italic: true),
    ]

    /// `@font-face` rules with the OTF bytes inlined. Built once and cached.
    /// If the bundle fonts can't be read (odd build, CLI harness with no
    /// Resources/fonts), this is empty and the page falls back to the CSS
    /// stack's system fonts — exactly the previous behaviour.
    private static let fontFaceCSS: String = buildFontFaceCSS()

    private static func buildFontFaceCSS() -> String {
        guard let fontsDir = Bundle.main.resourceURL?
            .appendingPathComponent("fonts", isDirectory: true) else { return "" }
        var rules = ""
        for face in embeddedFaces {
            let url = fontsDir.appendingPathComponent(face.file).appendingPathExtension("otf")
            guard let data = try? Data(contentsOf: url) else { continue }
            rules += """
            @font-face {
              font-family: "\(face.family)";
              font-style: \(face.italic ? "italic" : "normal");
              font-weight: \(face.weight);
              font-display: swap;
              src: url("data:font/otf;base64,\(data.base64EncodedString())") format("opentype");
            }

            """
        }
        return rules
    }

    /// Brand palette (Assets.xcassets values), light + dark.
    private static let css = """
    :root {
      --paper: #FAF6EC; --sand: #EBE4D4; --ink: #182642;
      --slate: #5B6270; --sage: #4E7168; --gold: #8A6D3B;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --paper: #131D31; --sand: #20304F; --ink: #F4EFE4;
        --slate: #99A3B5; --sage: #7BA99C; --gold: #C9A45E;
      }
    }
    * { box-sizing: border-box; }
    /* Explicit start-alignment: text-align inherits as a *physical* side, so
       an RTL child inside an LTR parent would otherwise stay left-stuck.
       Declared per element, start resolves against that element's own dir. */
    p, h1, h2, h3, h4, h5, h6, li, blockquote, th, td { text-align: start; }
    body {
      background: var(--paper); color: var(--ink);
      font-family: "IBM Plex Sans", "IBM Plex Sans Arabic", system-ui, sans-serif;
      line-height: 1.65; margin: 0;
    }
    main { max-width: 46rem; margin: 0 auto; padding: 2.2rem 1.6rem; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
    h1 { font-size: 1.9rem; } h2 { font-size: 1.55rem; } h3 { font-size: 1.28rem; }
    h4 { font-size: 1.1rem; }
    p, ul, ol { margin: 0.65em 0; }
    li { margin: 0.25em 0; }
    a { color: var(--gold); }
    pre {
      background: var(--sand); border-radius: 8px; padding: 0.85em 1em;
      overflow-x: auto; text-align: left;
    }
    code {
      font-family: "IBM Plex Mono", ui-monospace, "SF Mono", Menlo, monospace;
      font-size: 0.92em;
    }
    :not(pre) > code {
      background: var(--sand); border-radius: 4px; padding: 0.08em 0.35em;
    }
    blockquote {
      margin: 0.8em 0; padding-inline-start: 1em; margin-inline-start: 0;
      border-inline-start: 3px solid var(--sage); color: var(--slate);
    }
    hr { border: none; border-top: 1px solid var(--slate); opacity: 0.45; margin: 1.6em 0; }
    img { max-width: 100%; }
    table { border-collapse: collapse; margin: 0.8em 0; }
    th, td { border: 1px solid var(--sand); padding: 0.35em 0.7em; }
    th { background: var(--sand); }
    del { color: var(--slate); }
    /* Print / PDF: paper is always light (a dark fill wastes ink and reads
       wrong), content uses the full page width, and blocks avoid ugly page
       splits. Declared last so it wins over the dark-scheme block when a
       dark-mode machine prints. */
    @media print {
      :root {
        --paper: #FAF6EC; --sand: #EBE4D4; --ink: #182642;
        --slate: #5B6270; --sage: #4E7168; --gold: #8A6D3B;
      }
      body { background: #fff; }
      main { max-width: none; margin: 0; padding: 0; }
      h1, h2, h3, h4, h5, h6 { break-after: avoid; }
      pre, blockquote, table, img, li { break-inside: avoid; }
      pre { white-space: pre-wrap; word-wrap: break-word; }
    }
    """
}

private func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    mutating func children(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        children(markup)
    }

    // MARK: Blocks — explicit per-block direction, except code (pinned LTR)

    /// Explicit dir resolved from the block's first strong character —
    /// NOT dir="auto": the HTML first-strong algorithm skips descendants
    /// that carry their own dir attribute, so nested dir="auto" (ul → li →
    /// p) resolves to LTR everywhere and RTL list items end up with the
    /// marker on one side and left-stuck text. Resolving in Swift matches
    /// the editor's per-paragraph rule exactly and sidesteps the quirk.
    private func dirAttribute(_ markup: Markup) -> String {
        switch BidiDirection.firstStrong(in: contentText(markup)) {
        case .rightToLeft: return " dir=\"rtl\""
        case .leftToRight: return " dir=\"ltr\""
        case .neutral: return " dir=\"auto\""
        }
    }

    /// Text content in document order. (Not `format()` — swift-markdown
    /// traps when formatting table cells in isolation.)
    private func contentText(_ markup: Markup) -> String {
        if let text = markup as? Markdown.Text { return text.string }
        if let code = markup as? InlineCode { return code.code }
        if let code = markup as? CodeBlock { return code.code }
        return markup.children.map { contentText($0) }.joined(separator: " ")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p\(dirAttribute(paragraph))>\(children(paragraph))</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        "<h\(heading.level)\(dirAttribute(heading))>\(children(heading))</h\(heading.level)>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = codeBlock.language.map { " class=\"language-\(escapeHTML($0))\"" } ?? ""
        return "<pre dir=\"ltr\"><code\(lang)>\(escapeHTML(codeBlock.code))</code></pre>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote\(dirAttribute(blockQuote))>\n\(children(blockQuote))</blockquote>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul\(dirAttribute(list))>\n\(children(list))</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        "<ol\(dirAttribute(list))>\n\(children(list))</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        // Own direction so a mixed list resolves per item, exactly like the
        // editor's per-paragraph bars.
        "<li\(dirAttribute(listItem))>\(children(listItem))</li>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    // MARK: Tables (GFM)

    mutating func visitTable(_ table: Markdown.Table) -> String {
        "<table\(dirAttribute(table))>\n\(children(table))</table>\n"
    }

    mutating func visitTableHead(_ head: Markdown.Table.Head) -> String {
        let cells = head.children.map { "<th\(dirAttribute($0))>\(visit($0))</th>" }.joined()
        return "<thead><tr>\(cells)</tr></thead>\n"
    }

    mutating func visitTableBody(_ body: Markdown.Table.Body) -> String {
        "<tbody>\n\(children(body))</tbody>\n"
    }

    mutating func visitTableRow(_ row: Markdown.Table.Row) -> String {
        let cells = row.children.map { "<td\(dirAttribute($0))>\(visit($0))</td>" }.joined()
        return "<tr>\(cells)</tr>\n"
    }

    mutating func visitTableCell(_ cell: Markdown.Table.Cell) -> String {
        children(cell)
    }

    // MARK: Inlines

    mutating func visitText(_ text: Markdown.Text) -> String {
        escapeHTML(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(children(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(children(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(children(strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code dir=\"ltr\">\(escapeHTML(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Markdown.Link) -> String {
        let href = escapeHTML(link.destination ?? "#")
        return "<a href=\"\(href)\">\(children(link))</a>"
    }

    mutating func visitImage(_ image: Markdown.Image) -> String {
        let src = escapeHTML(image.source ?? "")
        let alt = escapeHTML(image.plainText)
        return "<img src=\"\(src)\" alt=\"\(alt)\">"
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        html.rawHTML
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }
}
