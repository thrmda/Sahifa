import Foundation

extension DelimitedText {
    /// A `.tsv` file is tab-separated whatever it contains; a `.csv` file's
    /// delimiter is detected.
    init(parsing text: String, kind: DocumentKind) {
        self.init(parsing: text, delimiter: kind == .tabSeparated ? .tab : nil)
    }
}

/// The preview page for a CSV or TSV file: the table, plus the few things
/// worth saying about it — a quote left open, rows left out, or no rows at
/// all.
enum TablePreview {
    static func body(from text: String, kind: DocumentKind,
                     rowLimit: Int = TableHTMLRenderer.defaultRowLimit) -> String {
        let table = DelimitedText(parsing: text, kind: kind)
        // The header isn't a row of data, so it isn't counted.
        let dataRows = max(table.rows.count - 1, 0)
        var html = ""
        // Above the table: an open quote explains why the table looks wrong.
        for problem in table.problems {
            switch problem {
            case .unclosedQuote(let line):
                html += note(String(localized: "Line \(line) opens a quote that is never closed, so everything after it is in one cell."),
                             warning: true)
            }
        }
        if table.rows.isEmpty {
            html += note(String(localized: "This file has no rows yet."))
        }
        html += TableHTMLRenderer.body(from: table, rowLimit: rowLimit)
        if dataRows > rowLimit {
            html += note(String(localized: "Showing the first \(rowLimit) of \(dataRows) rows."))
        }
        return html
    }

    /// The notes are interface text, so they take the app's language and its
    /// direction rather than the file's. Their own first strong character
    /// gives that: a note is only Arabic when the interface is.
    private static func note(_ text: String, warning: Bool = false) -> String {
        let direction = BidiDirection.firstStrong(in: text) == .rightToLeft ? "rtl" : "ltr"
        let classes = warning ? "sahifa-table-note warning" : "sahifa-table-note"
        return "<p class=\"\(classes)\" dir=\"\(direction)\">\(escapeHTML(text))</p>\n"
    }
}
