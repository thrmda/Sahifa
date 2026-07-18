import Foundation
import Compression

/// WebKit's `createPDF` writes each Arabic glyph's ToUnicode entry as the
/// *presentation form* it shaped to (U+FE70–FEFF, U+FB50–FDFF), so selecting
/// and copying Arabic from the exported PDF yields disconnected/garbled text
/// even though it renders correctly. This rewrites every ToUnicode CMap so the
/// copied text is the nominal Unicode letters (NFKC folds presentation forms
/// back to their base characters). Applied as a PDF *incremental update* —
/// existing bytes are never touched, so a parse failure anywhere degrades to
/// returning the input unchanged.
enum ArabicPDFTextFix {

    static func normalized(_ pdf: Data) -> Data {
        let text = latin1String(pdf)

        guard let oldStartxref = firstMatch(#"startxref\s+(\d+)\s*%%EOF\s*$"#, text, 1).flatMap({ Int($0) }),
              let root = firstMatch(#"/Root\s+(\d+)\s+\d+\s+R"#, text, 1).flatMap({ Int($0) }),
              let size = firstMatch(#"/Size\s+(\d+)"#, text, 1).flatMap({ Int($0) })
        else { return pdf }

        // Find stream objects whose inflated content is a ToUnicode CMap.
        let objPattern = #"(\d+)\s+\d+\s+obj\b(?:(?!endobj)[\s\S])*?stream\r?\n([\s\S]*?)\r?\nendstream"#
        guard let re = try? NSRegularExpression(pattern: objPattern) else { return pdf }
        let ns = text as NSString
        var edits: [Int: [UInt8]] = [:]
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let num = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let streamBytes = latin1Bytes(ns.substring(with: m.range(at: 2)))
            guard let infl = inflateZlib(streamBytes) else { continue }
            let content = String(decoding: infl, as: UTF8.self)
            guard content.contains("beginbfchar") || content.contains("beginbfrange") else { continue }
            let newCMap = rewriteCMap(content)
            edits[num] = Array(newCMap.utf8)
        }
        guard !edits.isEmpty else { return pdf }

        // Incremental update: append new (uncompressed) object versions, a new
        // xref subsection for them, and a trailer chaining to the old xref.
        var out = pdf
        if out.last != 0x0A { out.append(0x0A) }
        var offsets: [Int: Int] = [:]
        for num in edits.keys.sorted() {
            offsets[num] = out.count
            let cmap = edits[num]!
            var obj = "\(num) 0 obj\n<< /Length \(cmap.count) >>\nstream\n".data(using: .ascii)!
            obj.append(contentsOf: cmap)
            obj.append(contentsOf: Array("\nendstream\nendobj\n".utf8))
            out.append(obj)
        }
        let xrefOff = out.count
        var xref = "xref\n"
        for num in offsets.keys.sorted() {
            xref += "\(num) 1\n" + String(format: "%010d 00000 n \n", offsets[num]!)
        }
        xref += "trailer\n<< /Size \(size) /Root \(root) 0 R /Prev \(oldStartxref) >>\n"
        xref += "startxref\n\(xrefOff)\n%%EOF\n"
        out.append(xref.data(using: .ascii)!)
        return out
    }

    // MARK: CMap rewrite

    private static func rewriteCMap(_ text: String) -> String {
        var entries: [(String, String)] = []   // (srcHex, normalizedDstHex)

        forEachBlock("beginbfchar", "endbfchar", in: text) { body in
            let pair = try! NSRegularExpression(pattern: #"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>"#)
            let b = body as NSString
            for m in pair.matches(in: body, range: NSRange(location: 0, length: b.length)) {
                entries.append((b.substring(with: m.range(at: 1)), normHex(b.substring(with: m.range(at: 2)))))
            }
        }
        forEachBlock("beginbfrange", "endbfrange", in: text) { body in
            let triple = try! NSRegularExpression(pattern: #"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>"#)
            let b = body as NSString
            for m in triple.matches(in: body, range: NSRange(location: 0, length: b.length)) {
                guard let lo = Int(b.substring(with: m.range(at: 1)), radix: 16),
                      let hi = Int(b.substring(with: m.range(at: 2)), radix: 16) else { continue }
                let dst = b.substring(with: m.range(at: 3))
                var du = hexToBytes(dst)
                guard du.count >= 2 else { continue }
                for k in 0...(hi - lo) {
                    var d = du
                    let base = (Int(d[d.count-2]) << 8 | Int(d[d.count-1])) + k
                    d[d.count-2] = UInt8((base >> 8) & 0xFF); d[d.count-1] = UInt8(base & 0xFF)
                    entries.append((String(format: "%02X", lo + k), normHex(bytesToHex(d))))
                    _ = du
                }
            }
        }

        var s = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n"
        s += "/CMapName /Adobe-Identity-UCS def /CMapType 2 def\n"
        s += "1 begincodespacerange <00> <FF> endcodespacerange\n"
        var i = 0
        while i < entries.count {
            let chunk = entries[i..<min(i+100, entries.count)]
            s += "\(chunk.count) beginbfchar\n"
            for (src, dst) in chunk { s += "<\(src)> <\(dst)>\n" }
            s += "endbfchar\n"
            i += 100
        }
        s += "endcmap CMapName currentdict /CMap defineresource pop end end"
        return s
    }

    // MARK: helpers

    private static func normHex(_ hex: String) -> String {
        let bytes = hexToBytes(hex)
        guard let s = String(bytes: bytes, encoding: .utf16BigEndian) else { return hex }
        let n = s.precomposedStringWithCompatibilityMapping   // NFKC
        return n.utf16.map { String(format: "%04X", $0) }.joined()
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        let c = Array(hex); var out = [UInt8](); var i = 0
        while i + 1 < c.count {
            if let b = UInt8(String(c[i...i+1]), radix: 16) { out.append(b) }
            i += 2
        }
        return out
    }
    private static func bytesToHex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined() }

    private static func forEachBlock(_ open: String, _ close: String, in text: String, _ body: (String) -> Void) {
        guard let re = try? NSRegularExpression(pattern: open + #"([\s\S]*?)"# + close) else { return }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            body(ns.substring(with: m.range(at: 1)))
        }
    }

    private static func firstMatch(_ pattern: String, _ text: String, _ group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    private static func latin1String(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
    }
    private static func latin1Bytes(_ s: String) -> [UInt8] {
        s.unicodeScalars.map { UInt8($0.value & 0xFF) }
    }

    private static func inflateZlib(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 6 else { return nil }
        let body = Array(data[2...])   // strip 2-byte zlib header; Compression = raw DEFLATE
        let cap = max(body.count * 30, 1 << 16)
        var dst = [UInt8](repeating: 0, count: cap)
        let n = body.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, cap, src.baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < cap else { return nil }
        return Array(dst[0..<n])
    }
}
