import Foundation

/// Comma- or tab-separated text, split into rows of fields.
///
/// Read-only by design: nothing here turns rows back into a file. The table
/// is a view of the text, which is edited directly, so the file on disk keeps
/// its own quoting, spacing and line endings exactly.
///
/// RFC 4180, but lenient where real exports are messy: quoted fields may hold
/// delimiters, doubled quotes and line breaks; LF, CRLF and a lone CR all end
/// a row; rows may differ in length. A malformed file never fails to parse —
/// whatever parsed is kept, and what went wrong is listed in `problems`.
struct DelimitedText: Equatable {
    enum Delimiter: Character, CaseIterable {
        case comma = ","
        case semicolon = ";"
        case tab = "\t"
        case pipe = "|"
    }

    enum Problem: Equatable {
        /// A quoted field was still open at the end of the file, so everything
        /// after `line` ran into it.
        case unclosedQuote(line: Int)
    }

    let delimiter: Delimiter
    let rows: [[String]]
    let problems: [Problem]

    /// A nil delimiter is detected from the text. A caller that knows better
    /// passes it — a `.tsv` file is tab-separated whatever it contains.
    init(parsing text: String, delimiter: Delimiter? = nil) {
        let delimiter = delimiter ?? Self.detectDelimiter(in: text)
        let parsed = Self.parse(Array(text.unicodeScalars), delimiter: delimiter, rowLimit: nil)
        self.delimiter = delimiter
        self.rows = parsed.rows
        self.problems = parsed.problems
    }

    // MARK: Detection

    /// Rows detection looks at: enough to see past a title line or two, few
    /// enough to parse once per candidate without noticing.
    private static let detectionRows = 20
    private static let detectionScalars = 65_536

    /// The candidate that splits the opening rows most consistently into more
    /// than one column. `;` matters as much as `,`: spreadsheets in locales
    /// that write decimals with a comma export with it. Ties go to the order
    /// of `Delimiter.allCases`, so plain CSV wins, and so does a file with a
    /// single column.
    static func detectDelimiter(in text: String) -> Delimiter {
        let sample = Array(text.unicodeScalars.prefix(detectionScalars))
        let truncated = sample.count == detectionScalars
        var best: (delimiter: Delimiter, consistency: Double)?
        for candidate in Delimiter.allCases {
            var rows = parse(sample, delimiter: candidate, rowLimit: detectionRows).rows
            // A sample cut off mid-row would count that row short.
            if truncated, rows.count > 1, rows.count < detectionRows { rows.removeLast() }
            let counts = rows.map(\.count)
            guard let columns = mostCommon(counts), columns > 1 else { continue }
            let consistency = Double(counts.filter { $0 == columns }.count) / Double(counts.count)
            if best == nil || consistency > best!.consistency {
                best = (candidate, consistency)
            }
        }
        return best?.delimiter ?? .comma
    }

    /// The most frequent value, the larger one on a tie.
    private static func mostCommon(_ values: [Int]) -> Int? {
        var tally: [Int: Int] = [:]
        for value in values { tally[value, default: 0] += 1 }
        return tally.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
    }

    // MARK: Parsing

    /// Works on scalars rather than Characters: a delimiter followed by a
    /// combining mark would merge into one Character and stop splitting, and
    /// CRLF is a single Character too.
    private static func parse(_ scalars: [Unicode.Scalar], delimiter: Delimiter,
                              rowLimit: Int?) -> (rows: [[String]], problems: [Problem]) {
        let separator = delimiter.rawValue.unicodeScalars.first!
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false      // the current field opened with a quote
        var inQuotes = false
        var line = 1
        var quoteLine = 1

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            quoted = false
        }

        func endRow() {
            // A blank line is spacing, not a record with one empty field.
            let blank = row.isEmpty && field.isEmpty && !quoted
            endField()
            if !blank { rows.append(row) }
            row = []
        }

        func followedByLineFeed(_ index: Int) -> Bool {
            index + 1 < scalars.count && scalars[index + 1] == "\n"
        }

        var index = 0
        while index < scalars.count {
            if let rowLimit, rows.count >= rowLimit { break }
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    // Kept exactly, CR and all; only the line count cares.
                    if scalar == "\n" || (scalar == "\r" && !followedByLineFeed(index)) { line += 1 }
                    field.append(scalar)
                }
            } else if scalar == "\"", field.isEmpty, !quoted {
                inQuotes = true
                quoted = true
                quoteLine = line
            } else if scalar == separator {
                endField()
            } else if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", followedByLineFeed(index) { index += 1 }
                endRow()
                line += 1
            } else {
                // Includes a quote in the middle of a field, or after a
                // closing one: literal text rather than an error.
                field.append(scalar)
            }
            index += 1
        }

        var problems: [Problem] = []
        if inQuotes { problems.append(.unclosedQuote(line: quoteLine)) }
        if !row.isEmpty || !field.isEmpty || quoted { endRow() }
        return (rows, problems)
    }
}
