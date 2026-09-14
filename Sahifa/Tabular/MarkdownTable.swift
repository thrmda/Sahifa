import Foundation

/// Rows of cells to and from GitHub-flavoured Markdown table source, and out
/// to CSV. Plain text both ways: cell contents aren't escaped or interpreted
/// as Markdown, so `**bold**` copied out of a table keeps its markers and a
/// `*` pasted in stays what it was.
enum MarkdownTable {
    /// The first row is the header. Rows are padded to the widest and cells
    /// trimmed. The only escaping is what a table needs to stay a table: `|`
    /// becomes `\|`, and a line break inside a cell becomes `<br>`.
    static func markdown(from rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        let columns = max(1, rows.map(\.count).max() ?? 0)
        func line(_ cells: [String]) -> String {
            let padded = (0..<columns).map { $0 < cells.count ? cell(cells[$0]) : "" }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var lines = [line(header), "|" + String(repeating: " --- |", count: columns)]
        lines += rows.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }

    /// Cells from a table's source lines. The delimiter row is dropped, outer
    /// pipes are optional as they are in GFM, and `\|` and `<br>` come back as
    /// a pipe and a line break.
    static func rows(fromSource source: String) -> [[String]] {
        let lines = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.enumerated().compactMap { index, line in
            index == 1 && isDelimiterRow(line) ? nil : cells(of: line)
        }
    }

    /// RFC 4180: a field is quoted only when it holds a comma, a quote or a
    /// line break, with its quotes doubled. Rows end in a line feed.
    static func csv(from rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// A table inside a blockquote carries `>` markers on every line; they
    /// aren't part of any cell.
    static func strippingQuoteMarkers(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.drop { $0 == ">" || $0 == " " }) }
            .joined(separator: "\n")
    }

    // MARK: Helpers

    private static func cell(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func isDelimiterRow(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|:- \t".contains($0) }
    }

    private static func cells(of line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            if character == "\\", next < body.endIndex, body[next] == "|" {
                current.append("|")
                index = body.index(after: next)
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = next
        }
        cells.append(current)
        return cells.map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "<br />", with: "\n")
                .replacingOccurrences(of: "<br/>", with: "\n")
                .replacingOccurrences(of: "<br>", with: "\n")
        }
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
