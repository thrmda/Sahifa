import Foundation

/// A document's rendered HTML, whatever its kind. Decided in one place so the
/// live preview and an exported file can't show the same document two
/// different ways.
enum DocumentHTML {
    static func body(_ text: String, kind: DocumentKind) -> String {
        kind.isTable
            ? TablePreview.body(from: text, kind: kind)
            : MarkdownHTMLRenderer.body(from: text)
    }

    static func standalone(title: String, text: String, kind: DocumentKind) -> String {
        MarkdownHTMLRenderer.standalone(title: title, body: body(text, kind: kind))
    }
}
