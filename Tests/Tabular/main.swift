import Foundation

var failures = 0
var checksRun = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    checksRun += 1
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

func parse(_ text: String, _ delimiter: DelimitedText.Delimiter? = .comma) -> DelimitedText {
    DelimitedText(parsing: text, delimiter: delimiter)
}

// MARK: Parsing

func parsing() {
    check("rows split on the delimiter", parse("a,b\nc,d").rows == [["a", "b"], ["c", "d"]])
    check("a trailing newline doesn't add an empty row", parse("a,b\n").rows == [["a", "b"]])
    check("CRLF ends a row", parse("a,b\r\nc,d\r\n").rows == [["a", "b"], ["c", "d"]])
    check("a lone CR ends a row", parse("a\rb").rows == [["a"], ["b"]])
    check("empty fields are kept", parse("a,,c\nd,").rows == [["a", "", "c"], ["d", ""]])
    check("blank lines are skipped", parse("a\n\n\nb\n").rows == [["a"], ["b"]])
    check("…but a quoted empty line is a row", parse("a\n\"\"\nb").rows == [["a"], [""], ["b"]])
    check("a quoted field can hold the delimiter", parse("\"a,b\",c").rows == [["a,b", "c"]])
    check("a doubled quote is one quote",
          parse("\"say \"\"hi\"\"\",x").rows == [["say \"hi\"", "x"]])
    check("a quoted line break is kept exactly, CR included",
          parse("\"one\r\ntwo\",x\ny").rows == [["one\r\ntwo", "x"], ["y"]])
    check("a quote inside an unquoted field is literal",
          parse("5\" pipe,x").rows == [["5\" pipe", "x"]])
    check("text after a closing quote is kept", parse("\"ab\"c,d").rows == [["abc", "d"]])
    check("ragged rows keep their own lengths",
          parse("a,b,c\nd\ne,f,g,h").rows.map(\.count) == [3, 1, 4])
    check("Arabic fields come through intact",
          parse("الاسم,المدينة\nمحمد,الرياض").rows == [["الاسم", "المدينة"], ["محمد", "الرياض"]])
    check("the Arabic comma is not a delimiter", parse("أ، ب,ج").rows == [["أ، ب", "ج"]])
    check("an empty file has no rows or problems",
          parse("").rows.isEmpty && parse("").problems.isEmpty)

    let open = parse("a,b\nc,\"d\ne,f\ng")
    check("an unclosed quote is reported at the line it opened",
          open.problems == [.unclosedQuote(line: 2)], "\(open.problems)")
    check("…keeping everything that parsed",
          open.rows == [["a", "b"], ["c", "d\ne,f\ng"]], "\(open.rows)")
    let later = parse("\"x\ny\"\nz,\"w")
    check("line numbers count the breaks inside quotes",
          later.problems == [.unclosedQuote(line: 3)], "\(later.problems)")
    check("a well-formed file has no problems", parse("a,\"b\nc\"\n").problems.isEmpty)
}

// MARK: Detection

func detection() {
    func detect(_ text: String) -> DelimitedText.Delimiter {
        DelimitedText.detectDelimiter(in: text)
    }
    check("commas", detect("name,city\nAli,Riyadh\n") == .comma)
    check("semicolons, with decimal commas in the data",
          detect("item;price;qty\nتفاح;1,5;3\nموز;2,25;10\n") == .semicolon)
    check("tabs", detect("a\tb\tc\n1\t2\t3\n") == .tab)
    check("pipes", detect("a|b\n1|2\n") == .pipe)
    check("commas inside quotes don't outvote the real delimiter",
          detect("name;note\nA;\"x, y, z\"\nB;\"p, q\"\n") == .semicolon)
    check("a title line above the table doesn't throw it",
          detect("Report\na;b;c\n1;2;3\n4;5;6\n") == .semicolon)
    check("a single column falls back to commas", detect("one\ntwo\n") == .comma)
    check("an empty file falls back to commas", detect("") == .comma)
    check("an explicit delimiter overrides detection",
          DelimitedText(parsing: "a,b\tc", delimiter: .tab).rows == [["a,b", "c"]])
    check("without one, parsing uses what was detected",
          DelimitedText(parsing: "a;b\n1;2").delimiter == .semicolon)
}

// MARK: Rendering

func rendering() {
    func html(_ text: String, rowLimit: Int = TableHTMLRenderer.defaultRowLimit) -> String {
        TableHTMLRenderer.body(from: parse(text), rowLimit: rowLimit)
    }
    check("an Arabic header makes an RTL table",
          html("الاسم,العمر\nمحمد,30").contains("<table dir=\"rtl\">"))
    check("an English header makes an LTR table",
          html("name,age\nAli,30").contains("<table dir=\"ltr\">"))
    check("a header of numbers defers to the first row with letters",
          html("1,2\n3,4\nمحمد,5").contains("<table dir=\"rtl\">"))
    check("a table with no letters at all sets no direction", html("1,2\n3,4").contains("<table>"))

    let mixed = html("الاسم,البلد,العمر\nAli,السعودية,30\n")
    check("the first row is the header", mixed.contains("<thead><tr><th dir=\"rtl\">الاسم</th>"), mixed)
    check("an English cell in an Arabic table reads LTR", mixed.contains("<td dir=\"ltr\">Ali</td>"))
    check("an Arabic cell reads RTL", mixed.contains("<td dir=\"rtl\">السعودية</td>"))
    check("a numeric cell takes the table's direction, not dir=auto", mixed.contains("<td>30</td>"))

    check("cells are escaped, never markup",
          html("a,b\n<script>x</script>,&amp;")
            .contains("<td dir=\"ltr\">&lt;script&gt;x&lt;/script&gt;</td><td dir=\"ltr\">&amp;amp;</td>"))
    check("Markdown in a cell stays literal", html("a\n**b**").contains("<td dir=\"ltr\">**b**</td>"))
    check("a line break inside a cell becomes <br>",
          html("a\n\"one\r\ntwo\"").contains("<td dir=\"ltr\">one<br>two</td>"))

    let ragged = html("a,b,c\nd\ne,f,g,h")
    check("short rows are padded to the widest",
          ragged.contains("<tr><td dir=\"ltr\">d</td><td></td><td></td><td></td></tr>"), ragged)
    check("…and so is the header", ragged.contains("<th dir=\"ltr\">c</th><th></th></tr>"))

    let long = html("h\n1\n2\n3\n4\n5", rowLimit: 2)
    check("rows past the limit aren't rendered",
          long.components(separatedBy: "<tr>").count - 1 == 3, long)
    check("…counting body rows, not the header", long.contains("<td>2</td>") && !long.contains("<td>3</td>"))
    check("a header-only file has no body", !html("a,b").contains("<tbody>"))
    check("an empty file renders nothing", html("").isEmpty)
}

// MARK: The preview page

func preview() {
    // Only the English wording is checked, not the numbers in it: those are
    // formatted for the machine's locale.
    let empty = TablePreview.body(from: "", kind: .delimited)
    check("an empty file says it has no rows", empty.contains("This file has no rows yet."), empty)

    let open = TablePreview.body(from: "a,b\nc,\"d\ne", kind: .delimited)
    check("an unclosed quote is reported above the table",
          open.hasPrefix("<p class=\"sahifa-table-note warning\" dir=\"ltr\">Line ")
            && open.contains("opens a quote that is never closed"), open)

    let long = TablePreview.body(from: "h\n1\n2\n3", kind: .delimited, rowLimit: 2)
    check("rows left out are noted below the table",
          long.contains("</table></div>\n<p class=\"sahifa-table-note\" dir=\"ltr\">Showing the first "), long)
    check("a file within the limit says nothing extra",
          !TablePreview.body(from: "h\n1\n2", kind: .delimited, rowLimit: 2).contains("sahifa-table-note"))
    check("…and the header doesn't count towards the limit",
          !TablePreview.body(from: "h\n1\n2", kind: .delimited, rowLimit: 2).contains("Showing"))

    check("a .tsv file splits on tabs even where commas look likelier",
          TablePreview.body(from: "a,b,c\td\n1,2,3\t4", kind: .tabSeparated)
            .contains("<th dir=\"ltr\">a,b,c</th><th dir=\"ltr\">d</th>"))
    check("a .csv file detects its delimiter",
          TablePreview.body(from: "a;b\n1;2", kind: .delimited).contains("<th dir=\"ltr\">a</th><th dir=\"ltr\">b</th>"))
}

// MARK: Size

func size() {
    let big = (0..<50_000)
        .map { "\($0),محمد بن عبدالله,\"الرياض, السعودية\",2026-09-14" }
        .joined(separator: "\n")
    let parseStart = Date()
    let table = DelimitedText(parsing: big)
    let parseTime = Date().timeIntervalSince(parseStart)
    let renderStart = Date()
    let rendered = TableHTMLRenderer.body(from: table)
    let renderTime = Date().timeIntervalSince(renderStart)
    check("a 50,000-row file detects and parses completely",
          table.delimiter == .comma && table.rows.count == 50_000 && table.rows[1].count == 4)
    check("…and renders only up to the limit",
          rendered.components(separatedBy: "<tr>").count - 1 == TableHTMLRenderer.defaultRowLimit + 1)
    print(String(format: "INFO  50,000 rows: detect + parse %.0f ms, render %.0f ms",
                 parseTime * 1000, renderTime * 1000))
}

parsing()
detection()
rendering()
preview()
size()
if checksRun == 0 {
    print("\nNOTHING RAN")
    exit(1)
}
print(failures == 0 ? "\nALL PASS (\(checksRun) checks)" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
