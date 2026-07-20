import AppKit
import SwiftUI
import WebKit

/// Live HTML preview. Loads the page shell once, then swaps rendered content
/// in place via JS so the WebView keeps its scroll position while typing.
/// Updates are debounced — the editor's own restyle already parses on every
/// keystroke; the preview doesn't need to.
///
/// The WebView persists across document switches (no `.id` on this view):
/// the shell embeds ~1.7 MB of base64 fonts, so reloading it per switch
/// leaves the pane blank for the whole load. Instead the coordinator detects
/// a URL change, renders the new content immediately and resets the scroll.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let documentURL: URL?
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
        context.coordinator.webView = webView
        scrollSync?.previewWebView = webView
        context.coordinator.loadShell()
        context.coordinator.render(markdown, url: documentURL, immediately: true)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.scrollSync = scrollSync
        scrollSync?.previewWebView = webView
        context.coordinator.render(markdown, url: documentURL, immediately: false)
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
        private var pending: (markdown: String, resetScroll: Bool)?
        private var lastRendered: String?
        private var renderedURL: URL?
        private var debounce: Task<Void, Never>?

        init(scrollSync: ScrollSync?) {
            self.scrollSync = scrollSync
        }

        func loadShell() {
            shellReady = false
            webView?.loadHTMLString(MarkdownHTMLRenderer.previewShell(), baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "sahifaScroll",
                  let fraction = message.body as? Double else { return }
            scrollSync?.previewDidScroll(CGFloat(fraction))
        }

        func render(_ markdown: String, url: URL?, immediately: Bool) {
            let urlChanged = url != renderedURL
            renderedURL = url
            guard urlChanged || markdown != lastRendered else { return }
            pending = (markdown, urlChanged)
            debounce?.cancel()
            if immediately || urlChanged {
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
            guard shellReady, let webView, let update = pending else { return }
            pending = nil
            lastRendered = update.markdown
            let html = MarkdownHTMLRenderer.body(from: update.markdown)
            guard let data = try? JSONEncoder().encode(html),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("sahifaRender(\(json), \(update.resetScroll))") { [weak self] _, error in
                // A failed evaluate (page mid-reload, process just died) would
                // otherwise leave the pane blank until the *next* edit — put
                // the update back so didFinish / the next render retries it.
                guard let self, error != nil else { return }
                if self.pending == nil { self.pending = update }
                self.lastRendered = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellReady = true
            flush()
        }

        /// The preview only ever shows the shell. Clicking a link (or dropping
        /// a file on the pane) would otherwise navigate it away and leave the
        /// preview showing something that isn't the document — links go to the
        /// default browser instead, dropped files to AppModel.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType != .other else {
                decisionHandler(.allow)   // our own loadHTMLString
                return
            }
            decisionHandler(.cancel)
            guard let url = navigationAction.request.url else { return }
            if url.isFileURL {
                AppModel.shared.openExternal([url])
            } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }

        /// WebKit's content process can be killed (memory pressure, GPU
        /// hiccup); without this the pane goes permanently blank.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if pending == nil, let last = lastRendered {
                pending = (last, false)
            }
            lastRendered = nil
            loadShell()
        }
    }
}
