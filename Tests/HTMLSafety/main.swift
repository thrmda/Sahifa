import AppKit
import WebKit

var failures = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

// MARK: What the renderer writes

let hostile = """
# Notes

[click](javascript:alert(1)) [tabbed](java&#x09;script:alert(1)) [data](data:text/html,<b>x</b>)
[fine](https://example.com) [mail](mailto:a@example.com) [local](notes.md)

![pic](data:image/png;base64,AAAA) ![bad](javascript:alert(1))

<img src="x" onerror="window.pwned = 1">

<script>window.pwnedByScript = 1</script>
"""

let body = MarkdownHTMLRenderer.body(from: hostile)
check("a javascript: link is dropped", !body.contains("href=\"javascript:"))
check("…even with an encoded tab inside the scheme",
      body.contains("<a href=\"#\">tabbed</a>"))
check("a data: link is dropped", !body.contains("href=\"data:"))
check("http, mailto and relative links are kept",
      body.contains("href=\"https://example.com\"") && body.contains("href=\"mailto:a@example.com\"")
        && body.contains("href=\"notes.md\""))
check("a data: image is kept", body.contains("src=\"data:image/png;base64,AAAA\""))
check("a javascript: image source is dropped", !body.contains("src=\"javascript:"))

let refresh = MarkdownHTMLRenderer.body(from: """
<meta http-equiv="refresh" content="0;url=http://127.0.0.1:9/evil">

Text with an inline <META charset=x> tag and a kept <b>bold</b>.
""")
check("a meta refresh in raw HTML is dropped from the export", !refresh.lowercased().contains("<meta"))
check("…while other raw HTML stays", refresh.contains("<b>bold</b>"))

let exported = MarkdownHTMLRenderer.standalone(title: "t", markdown: hostile)
check("an exported page carries a Content Security Policy",
      exported.contains("http-equiv=\"Content-Security-Policy\""))
check("…that runs no script at all", exported.contains("script-src 'none'"))

let shell = MarkdownHTMLRenderer.previewShell()
let nonce = MarkdownHTMLRenderer.scriptNonce
check("the preview shell allows only its own script",
      shell.contains("script-src 'nonce-\(nonce)'") && shell.contains("<script nonce=\"\(nonce)\">"))

// MARK: What the preview actually runs

/// Spins the run loop until `done` or the timeout; WebKit works on it.
@MainActor
func wait(_ seconds: Double, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline, !done() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
final class Loaded: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

@MainActor
func evaluate(_ web: WKWebView, _ script: String) -> String {
    var result: String?
    web.evaluateJavaScript(script) { value, error in
        result = error.map { "error: \($0.localizedDescription)" } ?? "\(value ?? "nil")"
    }
    wait(5) { result != nil }
    return result ?? "timeout"
}

@MainActor
func previewChecks() {
    _ = NSApplication.shared
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let loaded = Loaded()
    web.navigationDelegate = loaded
    web.loadHTMLString(shell, baseURL: nil)
    wait(10) { loaded.finished }
    check("the preview shell loads", loaded.finished)

    guard let json = try? JSONEncoder().encode(body), let literal = String(data: json, encoding: .utf8)
    else { check("encode the body", false); return }
    let rendered = evaluate(web, "sahifaRender(\(literal), false); 'ok'")
    check("the app can still render into the shell", rendered == "ok", rendered)
    wait(1)
    check("…and the document shows",
          evaluate(web, "document.querySelector('h1') ? document.querySelector('h1').textContent : ''") == "Notes")
    check("an onerror handler in the document does not run",
          evaluate(web, "String(window.pwned === 1)") == "false")
    check("a script element in the document does not run",
          evaluate(web, "String(window.pwnedByScript === 1)") == "false")
}

MainActor.assumeIsolated { previewChecks() }
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
