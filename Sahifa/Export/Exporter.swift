import AppKit
import WebKit
import PDFKit
import UniformTypeIdentifiers

/// HTML / PDF export. HTML is a straight write of the standalone page; PDF
/// renders that page in an offscreen WKWebView and paginates it into A4 pages
/// with `createPDF` (see `PDFCapture` for why the Cocoa print system isn't
/// used), then repairs the Arabic text layer.
@MainActor
final class Exporter: NSObject {

    static let shared = Exporter()

    /// Keeps offscreen web views and their delegates alive until they finish.
    private var activeCaptures: [PDFCapture] = []

    // MARK: Panels

    func exportHTML(markdown: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = suggestedName + ".html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeHTML(markdown: markdown, title: suggestedName, to: url)
        } catch {
            presentError(error)
        }
    }

    func exportPDF(markdown: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writePDF(markdown: markdown, title: suggestedName, to: url) { [weak self] error in
            if let error { self?.presentError(error) }
        }
    }

    // MARK: Panel-free primitives (also used by the CLI dev flags)

    func writeHTML(markdown: String, title: String, to url: URL) throws {
        let html = MarkdownHTMLRenderer.standalone(title: title, markdown: markdown)
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    func writePDF(markdown: String, title: String, to url: URL,
                  completion: @escaping @MainActor (Error?) -> Void) {
        let html = MarkdownHTMLRenderer.standalone(title: title, markdown: markdown)
        let capture = PDFCapture(destination: url) { [weak self] capture, error in
            self?.activeCaptures.removeAll { $0 === capture }
            completion(error)
        }
        activeCaptures.append(capture)
        capture.start(html: html)
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    // MARK: Dev flags

    /// `-exportHTML <path>` / `-exportPDF <path>`: export the currently
    /// selected document without any panels, then quit. Testing hook.
    func handleCLIFlagsIfPresent(markdown: String?, title: String) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let path = value(after: "-exportHTML") {
            guard let markdown else { NSApp.terminate(nil); return }
            try? writeHTML(markdown: markdown, title: title, to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        } else if let path = value(after: "-exportPDF") {
            guard let markdown else { NSApp.terminate(nil); return }
            writePDF(markdown: markdown, title: title, to: URL(fileURLWithPath: path)) { _ in
                NSApp.terminate(nil)
            }
        }
    }
}

/// One offscreen render-to-PDF job. `WKWebView.printOperation` hangs / balloons
/// the file when driven from an offscreen view, so instead we slice the content
/// into A4-height pages ourselves with `createPDF` (one capture per page) and
/// stitch them with PDFKit. Page cuts are snapped to block boundaries so a
/// paragraph isn't split mid-line, and the finished PDF gets its Arabic
/// ToUnicode maps repaired (see `ArabicPDFTextFix`).
@MainActor
private final class PDFCapture: NSObject, WKNavigationDelegate {
    // A4 at CSS 96 dpi. createPDF maps 1 CSS px → 1 PDF point.
    private static let pageWidth: CGFloat = 794
    private static let pageHeight: CGFloat = 1123

    private let webView: WKWebView
    private let destination: URL
    private let completion: @MainActor (PDFCapture, Error?) -> Void

    init(destination: URL, completion: @escaping @MainActor (PDFCapture, Error?) -> Void) {
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0,
                                               width: Self.pageWidth, height: Self.pageHeight))
        self.destination = destination
        self.completion = completion
        super.init()
        // createPDF captures the *screen* rendering, so `@media print` never
        // fires — force light appearance so the page renders on light "paper"
        // (prefers-color-scheme resolves against the view's effective appearance)
        // instead of inheriting the system's dark mode.
        webView.appearance = NSAppearance(named: .aqua)
        webView.navigationDelegate = self
    }

    func start(html: String) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Setting the view's appearance doesn't reliably override
        // prefers-color-scheme, so force the light "paper" palette by injecting
        // an !important override of the CSS custom properties (custom-property
        // declarations honour !important and beat the dark @media block).
        let forceLight = """
        (function(){
          var s = document.createElement('style');
          s.textContent = ':root{--paper:#FAF6EC!important;--sand:#EBE4D4!important;\
        --ink:#182642!important;--slate:#5B6270!important;--sage:#4E7168!important;\
        --gold:#8A6D3B!important;}';
          document.head.appendChild(s);
        })();
        """
        webView.evaluateJavaScript(forceLight) { [self] _, _ in
            // Give layout/fonts a beat to settle before measuring.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in measure() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion(self, error)
    }

    /// Ask the page for its total height and the top/bottom of each top-level
    /// block (viewport-relative; unscrolled == document coordinates).
    private func measure() {
        let js = """
        (function(){
          var main = document.querySelector('main') || document.body;
          var out = { height: Math.ceil(document.documentElement.scrollHeight), blocks: [] };
          for (var i = 0; i < main.children.length; i++) {
            var r = main.children[i].getBoundingClientRect();
            out.blocks.push([Math.floor(r.top), Math.ceil(r.bottom)]);
          }
          return JSON.stringify(out);
        })();
        """
        webView.evaluateJavaScript(js) { [self] result, error in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let height = (obj["height"] as? NSNumber)?.doubleValue,
                  let blocks = obj["blocks"] as? [[Double]] else {
                completion(self, error ?? NSError(
                    domain: "Sahifa.Export", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not measure the document for pagination."]))
                return
            }
            let starts = pageStarts(contentHeight: CGFloat(height),
                                    blocks: blocks.map { (CGFloat($0[0]), CGFloat($0[1])) })
            renderPages(starts: starts, index: 0, into: PDFDocument())
        }
    }

    /// Greedy page fill: when a block would straddle the cut and it fits within
    /// a single page, push the whole block to the next page (snap the cut up to
    /// its top). Blocks taller than a page are cut (unavoidable).
    private func pageStarts(contentHeight: CGFloat, blocks: [(CGFloat, CGFloat)]) -> [CGFloat] {
        let pageH = Self.pageHeight
        var starts: [CGFloat] = []
        var start: CGFloat = 0
        while start < contentHeight - 1 {
            starts.append(start)
            var end = start + pageH
            if end < contentHeight {
                for (top, bottom) in blocks where top > start && top < end && bottom > end {
                    if (bottom - top) <= pageH { end = min(end, top) }
                }
                if end <= start { end = start + pageH }
            }
            start = end
        }
        return starts.isEmpty ? [0] : starts
    }

    private func renderPages(starts: [CGFloat], index: Int, into doc: PDFDocument) {
        guard index < starts.count else { finish(doc); return }
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: starts[index], width: Self.pageWidth, height: Self.pageHeight)
        webView.createPDF(configuration: config) { [self] result in
            switch result {
            case .success(let data):
                if let page = PDFDocument(data: data)?.page(at: 0) {
                    doc.insert(page, at: doc.pageCount)
                }
                renderPages(starts: starts, index: index + 1, into: doc)
            case .failure(let error):
                completion(self, error)
            }
        }
    }

    private func finish(_ doc: PDFDocument) {
        guard let data = doc.dataRepresentation() else {
            completion(self, NSError(domain: "Sahifa.Export", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not serialize the PDF."]))
            return
        }
        do {
            try ArabicPDFTextFix.normalized(data).write(to: destination)
            completion(self, nil)
        } catch {
            completion(self, error)
        }
    }
}
