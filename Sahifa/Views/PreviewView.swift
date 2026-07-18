import SwiftUI
import WebKit

/// Live HTML preview. Loads the page shell once, then swaps rendered content
/// in place via JS so the WebView keeps its scroll position while typing.
/// Updates are debounced — the editor's own restyle already parses on every
/// keystroke; the preview doesn't need to.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    var scrollSync: ScrollSync? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollSync: scrollSync)
    }

    func makeNSView(context: Context) -> WKWebView {
        // A content controller carries the scroll listener's messages back to
        // Swift (see the shell script in MarkdownHTMLRenderer.previewShell).
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "sahifaScroll")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Avoid an opaque white flash before the shell's CSS paints (dark mode).
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(MarkdownHTMLRenderer.previewShell(), baseURL: nil)
        context.coordinator.webView = webView
        scrollSync?.previewWebView = webView
        context.coordinator.render(markdown, immediately: true)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.scrollSync = scrollSync
        scrollSync?.previewWebView = webView
        context.coordinator.render(markdown, immediately: false)
    }

    /// Break the userContentController → coordinator retain when the preview
    /// is torn down (e.g. the split hides the preview).
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sahifaScroll")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var scrollSync: ScrollSync?
        private var shellReady = false
        private var pending: String?
        private var lastRendered: String?
        private var debounce: Task<Void, Never>?

        init(scrollSync: ScrollSync?) {
            self.scrollSync = scrollSync
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "sahifaScroll",
                  let fraction = message.body as? Double else { return }
            scrollSync?.previewDidScroll(CGFloat(fraction))
        }

        func render(_ markdown: String, immediately: Bool) {
            guard markdown != lastRendered else { return }
            pending = markdown
            debounce?.cancel()
            if immediately {
                flush()
            } else {
                debounce = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    self?.flush()
                }
            }
        }

        private func flush() {
            guard shellReady, let webView, let markdown = pending else { return }
            pending = nil
            lastRendered = markdown
            let html = MarkdownHTMLRenderer.body(from: markdown)
            guard let data = try? JSONEncoder().encode(html),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("sahifaRender(\(json))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellReady = true
            flush()
        }
    }
}
