import Foundation

/// Escapes text for HTML content or a double-quoted attribute value. Shared by
/// the Markdown and table renderers, and kept in its own file so the table
/// renderer's tests don't have to compile swift-markdown.
func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
