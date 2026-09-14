import Foundation

var failures = 0
var checksRun = 0
func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    checksRun += 1
    print("\(condition ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !condition { failures += 1 }
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sahifa-encoding-\(getpid())", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

let testSource = Source(id: UUID(), kind: .localFolder, name: "test", rootURL: dir)
let testStore = LocalFileStore(sourceID: testSource.id, root: dir)

func makeFile(_ name: String, _ bytes: [UInt8]) -> URL {
    let url = dir.appendingPathComponent(name)
    try! Data(bytes).write(to: url)
    return url
}

func onDisk(_ url: URL) -> [UInt8] {
    [UInt8]((try? Data(contentsOf: url)) ?? Data())
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
}

@MainActor
func makeDocument(_ url: URL) -> DocumentModel {
    DocumentModel(id: testSource.documentID(for: url)!, store: testStore)
}

@MainActor
func settle() async {
    try? await Task.sleep(nanoseconds: 300_000_000)
}

let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
/// "محمد,1" in Windows-1256 — what an older Arabic Excel export looks like, and
/// not valid UTF-8.
let windows1256: [UInt8] = [0xE3, 0xCD, 0xE3, 0xCF, 0x2C, 0x31]
let sample = "Hello مرحبا\r\nsecond line ✓ 😀\n"

// MARK: The codec

func codec() {
    for encoding in [TextEncoding.utf8, .utf8WithBOM, .utf16LittleEndian, .utf16BigEndian] {
        let data = encoding.encode(sample)
        let decoded = TextEncoding.decode(data)
        check("\(encoding) round-trips the text and the encoding",
              decoded?.text == sample && decoded?.encoding == encoding)
        check("…and re-encodes to the same bytes",
              decoded.map { $0.encoding.encode($0.text) } == data)
    }

    // Hand-built bytes, so decode and encode can't agree on a shared mistake.
    let marked = TextEncoding.decode(Data(bom + Array("a,b".utf8)))
    check("a UTF-8 BOM is recognised and kept out of the text",
          marked?.text == "a,b" && marked?.encoding == .utf8WithBOM)
    let little = TextEncoding.decode(Data([0xFF, 0xFE, 0x44, 0x06, 0x0D, 0x00, 0x0A, 0x00]))
    check("UTF-16 LE behind a BOM decodes",
          little?.text == "\u{0644}\r\n" && little?.encoding == .utf16LittleEndian)
    let big = TextEncoding.decode(Data([0xFE, 0xFF, 0x06, 0x44]))
    check("UTF-16 BE behind a BOM decodes",
          big?.text == "\u{0644}" && big?.encoding == .utf16BigEndian)
    check("an empty file is UTF-8", TextEncoding.decode(Data())?.encoding == .utf8)
    check("a second U+FEFF after the BOM is text, and kept",
          TextEncoding.decode(Data(bom + bom + [0x61]))?.text == "\u{FEFF}a")
    check("a real U+FFFD in valid UTF-8 isn't mistaken for damage",
          TextEncoding.decode(Data("a\u{FFFD}b".utf8))?.text == "a\u{FFFD}b")

    check("Windows-1256 is refused", TextEncoding.decode(Data(windows1256)) == nil)
    check("a truncated UTF-8 sequence is refused", TextEncoding.decode(Data([0x61, 0xD9])) == nil)
    check("odd-length UTF-16 is refused", TextEncoding.decode(Data([0xFF, 0xFE, 0x61])) == nil)
    check("a lone UTF-16 surrogate is refused",
          TextEncoding.decode(Data([0xFF, 0xFE, 0x00, 0xD8])) == nil)
    check("UTF-32 is refused rather than misread as UTF-16",
          TextEncoding.decode(Data([0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00])) == nil)
}

// MARK: Documents on disk

@MainActor
func documents() async {
    // 1. A UTF-8 BOM survives a save — Excel needs it to read Arabic.
    do {
        let url = makeFile("bom.csv", bom + Array("name,city\r\n".utf8))
        let doc = makeDocument(url)
        check("a file with a BOM opens editable", !doc.isReadOnly)
        check("…with the BOM kept out of the text", doc.text == "name,city\r\n",
              doc.text.debugDescription)
        doc.text = "name,city\r\nمحمد,الرياض\r\n"
        await doc.flush()
        check("saving keeps the BOM and the CRLFs",
              onDisk(url) == bom + Array("name,city\r\nمحمد,الرياض\r\n".utf8), hex(onDisk(url)))
    }

    // 2. Plain UTF-8 doesn't gain one.
    do {
        let url = makeFile("plain.md", Array("# عنوان\n".utf8))
        let doc = makeDocument(url)
        doc.text = "# عنوان\n\nنص\n"
        await doc.flush()
        check("plain UTF-8 is saved without a BOM",
              onDisk(url) == Array("# عنوان\n\nنص\n".utf8), hex(onDisk(url)))
    }

    // 3. UTF-16 stays UTF-16.
    do {
        let url = makeFile("wide.md", [0xFF, 0xFE, 0x61, 0x00])
        let doc = makeDocument(url)
        check("a UTF-16 file opens editable with its text", !doc.isReadOnly && doc.text == "a")
        doc.text = "ab"
        await doc.flush()
        check("saving writes UTF-16 LE with its BOM",
              onDisk(url) == [0xFF, 0xFE, 0x61, 0x00, 0x62, 0x00], hex(onDisk(url)))
    }

    // 4. The bug this suite exists for: a file that isn't Unicode used to open
    //    as an empty editor, and the first autosave replaced it.
    do {
        let url = makeFile("export.csv", windows1256)
        let doc = makeDocument(url)
        check("a Windows-1256 file opens read-only", doc.isReadOnly && doc.isUndecodable)
        check("…showing something rather than an empty editor", !doc.text.isEmpty)
        doc.text = "typed over it"
        doc.saveNow()
        await doc.flush()
        await settle()
        check("…and editing it never reaches the file", onDisk(url) == windows1256, hex(onDisk(url)))
    }

    // 5. Present but unreadable gets the same protection.
    do {
        let url = makeFile("locked.md", Array("secret".utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        if (try? Data(contentsOf: url)) != nil {
            print("SKIP  unreadable-file checks — this user can read a mode-000 file")
        } else {
            let doc = makeDocument(url)
            check("a file that can't be read opens read-only", doc.isReadOnly)
            doc.text = "replacement"
            await doc.flush()
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            check("…and is not overwritten", onDisk(url) == Array("secret".utf8), hex(onDisk(url)))
        }
    }

    // 6. Converted to UTF-8 by another program: it becomes editable.
    do {
        let url = makeFile("converted.csv", windows1256)
        let doc = makeDocument(url)
        try! Data("محمد,1\n".utf8).write(to: url)
        doc.reconcileWithDisk()
        check("a file converted to UTF-8 elsewhere follows", doc.text == "محمد,1\n", doc.text)
        check("…and is editable again", !doc.isReadOnly)
        doc.text = "محمد,2\n"
        await doc.flush()
        check("…and saves", onDisk(url) == Array("محمد,2\n".utf8), hex(onDisk(url)))
    }

    // 7. And the reverse: replaced by something undecodable, it locks.
    do {
        let url = makeFile("replaced.csv", Array("a,b\n".utf8))
        let doc = makeDocument(url)
        try! Data(windows1256).write(to: url)
        doc.reconcileWithDisk()
        check("a file replaced by Windows-1256 elsewhere turns read-only", doc.isReadOnly)
        doc.text = "a,b,c\n"
        await doc.flush()
        check("…and isn't overwritten", onDisk(url) == windows1256, hex(onDisk(url)))
    }

    // 8. A document that doesn't exist yet is still writable, as UTF-8.
    do {
        let id = testSource.documentID(for: dir.appendingPathComponent("new.md"))!
        let contents = testStore.readImmediately(id)
        check("an absent document reads as writable UTF-8",
              contents?.encoding == .utf8 && contents?.version == nil)
    }
}

codec()
await documents()
if checksRun == 0 {
    print("\nNOTHING RAN")
    exit(1)
}
print(failures == 0 ? "\nALL PASS (\(checksRun) checks)" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
