import Foundation

/// A parsed delimited file as an HTML table, for the same preview page the
/// Markdown renderer fills.
///
/// Cells are plain text: escaped, never read as Markdown or HTML, so `*` in a
/// cell stays a `*`. Direction follows the rules the editor and the Markdown
/// preview already use, with one deliberate difference for cells that carry
/// no letters (see `cellDirection`).
enum TableHTMLRenderer {
    /// Body rows past this aren't rendered. A 50,000-row export would
    /// otherwise stall the preview on every keystroke for rows nobody scrolls
    /// to; the caller says how many were left out.
    static let defaultRowLimit = 2_000

    /// The first row is always the header. An empty file renders nothing.
    static func body(from table: DelimitedText, rowLimit: Int = defaultRowLimit) -> String {
        guard let header = table.rows.first else { return "" }
        let bodyRows = table.rows.dropFirst().prefix(rowLimit)
        // Every row is padded to the widest, header included, so a ragged
        // file still lines up in columns.
        let columns = max(header.count, bodyRows.map(\.count).max() ?? 0)

        var html = "<div class=\"sahifa-table\"><table\(tableDirection([header] + bodyRows))>\n"
        html += "<thead><tr>\(cells(header, tag: "th", columns: columns))</tr></thead>\n"
        if !bodyRows.isEmpty {
            html += "<tbody>\n"
            for row in bodyRows {
                html += "<tr>\(cells(row, tag: "td", columns: columns))</tr>\n"
            }
            html += "</tbody>\n"
        }
        return html + "</table></div>\n"
    }

    /// The table's direction decides column order — an Arabic file puts its
    /// first column on the right. Resolved from the first strong character in
    /// reading order, which is what a Markdown table's direction comes from
    /// too: the header when it has letters, otherwise the first row that does.
    private static func tableDirection(_ rows: [[String]]) -> String {
        for row in rows {
            for field in row {
                switch BidiDirection.firstStrong(in: field) {
                case .rightToLeft: return " dir=\"rtl\""
                case .leftToRight: return " dir=\"ltr\""
                case .neutral: continue
                }
            }
        }
        return ""
    }

    private static func cells(_ fields: [String], tag: String, columns: Int) -> String {
        var html = ""
        for index in 0..<columns {
            let field = index < fields.count ? fields[index] : ""
            html += "<\(tag)\(cellDirection(field))>\(cellContent(field))</\(tag)>"
        }
        return html
    }

    /// Only a cell with a strong character gets a direction of its own. A cell
    /// of digits, a date or nothing at all inherits the table's. This is where
    /// it parts from the Markdown renderer's `dir="auto"`, which resolves such
    /// a cell LTR and so left-aligns a number inside an RTL table, leaving the
    /// column ragged.
    private static func cellDirection(_ field: String) -> String {
        switch BidiDirection.firstStrong(in: field) {
        case .rightToLeft: return " dir=\"rtl\""
        case .leftToRight: return " dir=\"ltr\""
        case .neutral: return ""
        }
    }

    /// A line break inside a quoted field is part of the cell.
    private static func cellContent(_ field: String) -> String {
        escapeHTML(field)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
