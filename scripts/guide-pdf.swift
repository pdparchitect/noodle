// Builds one of an app's guides as a PDF from its docs folder, for scripts/build-guides.sh, which compiles it
// together with NoodleDocument's MarkdownDocument.swift.
//   guide-pdf DOCS GUIDE TITLE APP VERSION ICON SOURCE OUT
// A page joins a guide by naming it in its front matter, between two `---` lines at the top of the file:
//   guides: [setup, user]
//   order: 10
// Pages go in order (100 when not given), then by title; each page's first heading is its chapter title. Links to
// pages in the guide become links inside the PDF; links to anything else go to SOURCE, the docs folder's web address.
// WebKit lays the pages out and prints them; PDFKit then reads where each heading landed, which a second print puts
// in the contents, and Core Graphics adds the page numbers, links and outline in a last pass.
import AppKit
import PDFKit
import WebKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("guide-pdf: " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 9 else { fail("usage: guide-pdf DOCS GUIDE TITLE APP VERSION ICON SOURCE OUT") }
let docs = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let guide = arguments[2], guideTitle = arguments[3], app = arguments[4], version = arguments[5]
let icon = URL(fileURLWithPath: arguments[6])
let source = arguments[7].hasSuffix("/") ? String(arguments[7].dropLast()) : arguments[7]
let output = URL(fileURLWithPath: arguments[8])

// MARK: Pages

struct Heading {
    let level: Int
    let title: String
    let id: String
}

struct Page {
    let path: String
    let order: Int
    let blocks: [MarkdownDocument.Block]
    var key: String { "p-" + String(String(path.dropLast(3)).lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }) }
    var title: String {
        for case .heading(1, let text) in blocks { return String(text.characters) }
        return String(path.dropLast(3))
    }
    /// The chapter's first heading and every level 2 heading, which the contents and outline list.
    var headings: [Heading] {
        var found: [Heading] = []
        for case .heading(let level, let text) in blocks where level <= 2 {
            if level == 1, found.contains(where: { $0.level == 1 }) { continue }
            found.append(Heading(level: level, title: String(text.characters), id: anchor(String(text.characters))))
        }
        if found.first?.level != 1 { found.insert(Heading(level: 1, title: title, id: key), at: 0) }
        return found
    }
    func anchor(_ heading: String) -> String { key + "--" + slug(heading) }
}

/// GitHub's anchor for a heading, so links written for GitHub find the same heading here.
func slug(_ text: String) -> String {
    String(text.lowercased().compactMap { $0 == " " ? "-" : ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : nil })
}

/// The front matter's fields, and the text after it.
func frontMatter(of text: String) -> ([String: String], String) {
    let lines = text.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
          let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], text) }
    var fields: [String: String] = [:]
    for line in lines[1..<end] {
        guard let colon = line.firstIndex(of: ":") else { continue }
        fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return (fields, lines[(end + 1)...].joined(separator: "\n"))
}

func dataURL(_ file: URL) -> String {
    guard let data = try? Data(contentsOf: file) else { fail("cannot read \(file.path)") }
    let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
                 "avif": "image/avif", "webp": "image/webp"]
    return "data:\(types[file.pathExtension.lowercased()] ?? "application/octet-stream");base64,\(data.base64EncodedString())"
}

/// Relative links point at their page on the web, which the HTML turns back into a link inside the guide when the
/// page is in it; MarkdownDocument keeps only web links. Images are read into the page itself.
func resolvingLinks(in markdown: String, of path: String) -> String {
    let folder = (path as NSString).deletingLastPathComponent
    let pageWeb = URL(string: source + "/" + (folder.isEmpty ? "" : folder + "/"))!
    let pattern = try! NSRegularExpression(pattern: #"(!?)\[([^\]]*)\]\(([^)\s]+)\)"#)
    let text = markdown as NSString
    var result = "", last = 0
    for match in pattern.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
        let image = text.substring(with: match.range(at: 1)) == "!"
        let label = text.substring(with: match.range(at: 2)), target = text.substring(with: match.range(at: 3))
        result += text.substring(with: NSRange(location: last, length: match.range.location - last))
        last = match.range.location + match.range.length
        let resolved: String
        if target.contains("://") || target.hasPrefix("mailto:") {
            resolved = target
        } else if image {
            resolved = dataURL(docs.appendingPathComponent(folder).appendingPathComponent(target).standardizedFileURL)
        } else if target.hasPrefix("#") {
            resolved = source + "/" + path + target
        } else {
            resolved = URL(string: target, relativeTo: pageWeb)?.absoluteString ?? target
        }
        result += "\(image ? "!" : "")[\(label)](\(resolved))"
    }
    return result + text.substring(from: last)
}

var pages: [Page] = []
let enumerator = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: nil)
while let file = enumerator?.nextObject() as? URL {
    guard file.pathExtension == "md", !["AGENTS.md", "CLAUDE.md"].contains(file.lastPathComponent) else { continue }
    let path = String(file.standardizedFileURL.path.dropFirst(docs.path.count + 1))
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { fail("cannot read \(path)") }
    let (fields, body) = frontMatter(of: text)
    let guides = (fields["guides"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard guides.contains(guide) else { continue }
    pages.append(Page(path: path, order: fields["order"].flatMap { Int($0) } ?? 100,
                      blocks: MarkdownDocument(resolvingLinks(in: body, of: path)).blocks))
}
pages.sort { ($0.order, $0.title.lowercased()) < ($1.order, $1.title.lowercased()) }
guard !pages.isEmpty else { fail("no page in \(docs.path) names the guide \(guide)") }
let pagesByPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })

// MARK: HTML

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// A link to a page in the guide, or to one of its headings, stays inside the PDF.
func href(_ link: URL) -> String {
    let address = link.absoluteString
    guard address.hasPrefix(source + "/") else { return address }
    let rest = address.dropFirst(source.count + 1)
    let path = String(rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    guard let page = pagesByPath[path] else { return address }
    guard let fragment = link.fragment, !fragment.isEmpty else { return "#" + page.key }
    return "#" + page.key + "--" + fragment
}

func inline(_ text: AttributedString) -> String {
    var html = ""
    for run in text.runs {
        let characters = String(text[run.range].characters)
        if let image = run.imageURL {
            html += "<img src=\"\(escape(image.absoluteString))\" alt=\"\(escape(characters))\">"
            continue
        }
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.softBreak) { html += " "; continue }
        if intent.contains(.lineBreak) { html += "<br>"; continue }
        var piece = escape(characters).replacingOccurrences(of: "\n", with: "<br>")
        if intent.contains(.code) { piece = "<code>\(piece)</code>" }
        if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
        if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
        if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
        if let link = run.link { piece = "<a href=\"\(escape(href(link)))\">\(piece)</a>" }
        html += piece
    }
    return html
}

func chapter(_ page: Page) -> String {
    var html = "<section class=\"chapter\" id=\"\(page.key)\">"
    var titled = false
    for block in page.blocks {
        switch block {
        case .heading(let level, let text):
            let first = level == 1 && !titled
            titled = titled || level == 1
            let shown = first ? 1 : min(level + 1, 6)
            html += "<h\(shown) id=\"\(page.anchor(String(text.characters)))\">\(inline(text))</h\(shown)>"
        case .paragraph(let text):
            html += "<p>\(inline(text))</p>"
        case .listItem(let item):
            let marker = item.task.map { $0 == .done ? "☑" : "☐" } ?? item.marker
            html += "<div class=\"item\" style=\"margin-left: \((item.depth - 1) * 18)pt\"><span class=\"marker\">\(escape(marker))</span><div>\(inline(item.text))</div></div>"
        case .quote(let text):
            html += "<blockquote>\(inline(text))</blockquote>"
        case .code(_, let code):
            html += "<pre><code>\(escape(code))</code></pre>"
        case .table(let table):
            let align = table.alignments.map { $0 == .center ? "center" : $0 == .trailing ? "right" : "left" }
            html += "<table><thead><tr>"
            for (column, cell) in table.header.enumerated() { html += "<th style=\"text-align: \(align[column])\">\(inline(cell))</th>" }
            html += "</tr></thead><tbody>"
            for row in table.rows {
                html += "<tr>"
                for (column, cell) in row.enumerated() { html += "<td style=\"text-align: \(align[column])\">\(inline(cell))</td>" }
                html += "</tr>"
            }
            html += "</tbody></table>"
        case .rule:
            html += "<hr>"
        }
    }
    return html + "</section>"
}

let contents = pages.flatMap { page in page.headings.map { (page, $0) } }

let style = """
@page { margin: 20mm 20mm 22mm 20mm; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { margin: 0; font: 10pt/1.5 -apple-system, "Helvetica Neue", sans-serif; color: #1d1d1f; -webkit-hyphens: auto; }
a { color: #0b57d0; text-decoration: none; }
.cover { height: 225mm; display: flex; flex-direction: column; justify-content: center; align-items: center; text-align: center; }
.cover img { width: 46mm; height: 46mm; }
.cover .app { font-size: 34pt; font-weight: 700; margin: 8mm 0 0; letter-spacing: -0.5pt; }
.cover .guide { font-size: 18pt; color: #424245; margin: 2mm 0 0; }
.cover .meta { font-size: 10pt; color: #6e6e73; margin-top: 14mm; }
.contents, .chapter { break-before: page; }
.contents h1 { margin-bottom: 6mm; }
.entry { display: flex; align-items: baseline; color: #1d1d1f; padding: 1.2pt 0; }
.entry .title { flex: 1; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.entry .number { width: 12mm; text-align: right; color: #6e6e73; font-variant-numeric: tabular-nums; }
.entry.level1 { font-weight: 600; margin-top: 5pt; }
.entry.level2 { padding-left: 6mm; }
h1 { font-size: 22pt; line-height: 1.2; margin: 0 0 5mm; letter-spacing: -0.3pt; }
h2 { font-size: 14pt; margin: 7mm 0 2mm; }
h3 { font-size: 11.5pt; margin: 5mm 0 1.5mm; }
h4, h5, h6 { font-size: 10pt; margin: 4mm 0 1mm; }
h2, h3, h4, h5, h6 { break-after: avoid; line-height: 1.25; }
p { margin: 0 0 2.5mm; orphans: 3; widows: 3; }
.item { display: flex; margin-bottom: 1.2mm; }
.item .marker { flex: none; min-width: 5mm; padding-right: 1.5mm; color: #6e6e73; }
code { font: 8.8pt "SF Mono", Menlo, monospace; -webkit-hyphens: none; background: #f2f2f4; border-radius: 2pt; padding: 0.5pt 2pt; }
pre { background: #f5f5f7; border-radius: 4pt; padding: 3mm 4mm; margin: 0 0 3mm; white-space: pre-wrap; word-break: break-all; break-inside: avoid; }
pre code { background: none; padding: 0; }
blockquote { margin: 0 0 3mm; padding-left: 4mm; border-left: 2.5pt solid #d2d2d7; color: #424245; }
table { border-collapse: collapse; width: 100%; margin: 0 0 3mm; font-size: 9pt; }
th, td { border-bottom: 0.5pt solid #d2d2d7; padding: 1.5mm 2mm; vertical-align: top; }
th { border-bottom-width: 1pt; }
tr { break-inside: avoid; }
hr { border: none; border-top: 0.5pt solid #d2d2d7; margin: 5mm 0; }
img { max-width: 100%; }
p img { display: block; margin: 2mm auto; border-radius: 4pt; }
"""

let date = { () -> String in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_GB")
    formatter.dateFormat = "d MMMM yyyy"
    return formatter.string(from: Date())
}()

/// The guide as one HTML page; `numbers` are the contents' page numbers, blank until the first print finds them.
func html(numbers: [Int]?) -> String {
    var html = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><style>\(style)</style></head><body>"
    html += "<section class=\"cover\"><img src=\"\(dataURL(icon))\" alt=\"\"><p class=\"app\">\(escape(app))</p>"
    html += "<p class=\"guide\">\(escape(guideTitle))</p><p class=\"meta\">Version \(escape(version)) · \(date)</p></section>"
    html += "<nav class=\"contents\"><h1>Contents</h1>"
    for (index, (_, heading)) in contents.enumerated() {
        let number = numbers.map { String($0[index]) } ?? ""
        html += "<a class=\"entry level\(heading.level)\" href=\"#\(heading.id)\">"
        html += "<span class=\"title\">\(escape(heading.title))</span><span class=\"number\">\(number)</span></a>"
    }
    html += "</nav>"
    for page in pages { html += chapter(page) }
    return html + "</body></html>"
}

// MARK: Printing

final class Loader: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
}

final class PrintDone: NSObject {
    var finished = false
    var success = false
    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        self.success = success
        finished = true
    }
}

func spin(until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(120)
    while !done() {
        guard Date() < deadline else { fail("timed out waiting for WebKit") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

_ = NSApplication.shared
let a4 = NSSize(width: 595.28, height: 841.89)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("guide-pdf-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

/// Prints the HTML to a PDF on A4 pages, in a window that is never shown, as WebKit prints only a view in one.
func printPDF(_ html: String, named name: String) -> PDFDocument {
    let configuration = WKWebViewConfiguration()
    configuration.preferences.shouldPrintBackgrounds = true
    let web = WKWebView(frame: NSRect(origin: .zero, size: NSSize(width: 800, height: 1000)), configuration: configuration)
    let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = web
    let loader = Loader()
    web.navigationDelegate = loader
    let page = scratch.appendingPathComponent(name + ".html")
    do { try html.write(to: page, atomically: true, encoding: .utf8) } catch { fail("cannot write \(page.path)") }
    web.loadFileURL(page, allowingReadAccessTo: scratch)
    spin { loader.finished || loader.failure != nil }
    if let failure = loader.failure { fail("WebKit could not load the guide: \(failure.localizedDescription)") }

    let pdf = scratch.appendingPathComponent(name + ".pdf")
    let info = NSPrintInfo()
    info.paperSize = a4
    info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
    let operation = web.printOperation(with: info)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    operation.view?.frame = web.bounds
    let done = PrintDone()
    operation.runModal(for: window, delegate: done, didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    spin { done.finished }
    guard done.success, let document = PDFDocument(url: pdf) else { fail("WebKit could not print the guide") }
    return document
}

/// Where each contents entry leads: its links come first, on the pages before the first chapter.
func destinations(in document: PDFDocument) -> [PDFDestination] {
    var found: [PDFDestination] = []
    var firstChapter = Int.max
    var index = 1
    while index < min(document.pageCount, firstChapter), let page = document.page(at: index) {
        let links = page.annotations.filter { $0.destination != nil || ($0.action as? PDFActionGoTo) != nil }
            .sorted { $0.bounds.maxY > $1.bounds.maxY }
        for link in links {
            guard let destination = link.destination ?? (link.action as? PDFActionGoTo)?.destination,
                  let target = destination.page else { continue }
            if found.isEmpty { firstChapter = document.index(for: target) }
            found.append(destination)
        }
        index += 1
    }
    guard found.count == contents.count else { fail("found \(found.count) of the \(contents.count) contents entries in the PDF") }
    return found
}

let draft = printPDF(html(numbers: nil), named: "draft")
let draftPages = destinations(in: draft).map { draft.index(for: $0.page!) + 1 }
let printed = printPDF(html(numbers: draftPages), named: "guide")
let targets = destinations(in: printed)
guard targets.map({ printed.index(for: $0.page!) + 1 }) == draftPages else { fail("the page numbers moved between prints") }

// MARK: Numbers, links and outline

// Core Graphics draws the pages again with their numbers, and writes their links and the outline, which PDFKit
// leaves out when it saves.
func target(of link: PDFAnnotation) -> PDFDestination? { link.destination ?? (link.action as? PDFActionGoTo)?.destination }
func name(of destination: PDFDestination) -> String {
    "d\(printed.index(for: destination.page!))-\(Int(destination.point.x))-\(Int(destination.point.y))"
}
var anchors: [Int: [String: CGPoint]] = [:]
for index in 0..<printed.pageCount {
    for link in printed.page(at: index)?.annotations ?? [] {
        guard let destination = target(of: link) else { continue }
        anchors[printed.index(for: destination.page!), default: [:]][name(of: destination)] = destination.point
    }
}

guard let printedData = printed.dataRepresentation(), let provider = CGDataProvider(data: printedData as CFData),
      let pdf = CGPDFDocument(provider),
      let context = CGContext(output as CFURL, mediaBox: nil, [
          kCGPDFContextTitle: "\(app) \(guideTitle)", kCGPDFContextAuthor: app, kCGPDFContextCreator: app,
          kCGPDFContextSubject: "\(app) \(guideTitle), version \(version)",
      ] as CFDictionary) else { fail("cannot write \(output.path)") }
let footer: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor(white: 0.45, alpha: 1)]
for number in 1...pdf.numberOfPages {
    guard let page = pdf.page(at: number) else { continue }
    var box = page.getBoxRect(.mediaBox)
    context.beginPage(mediaBox: &box)
    context.drawPDFPage(page)
    if number > 1 {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let left = NSAttributedString(string: "\(app) \(guideTitle)", attributes: footer)
        let right = NSAttributedString(string: "\(number)", attributes: footer)
        let margin = box.width * 20 / 210, baseline: CGFloat = 30
        left.draw(at: NSPoint(x: margin, y: baseline))
        right.draw(at: NSPoint(x: box.width - margin - right.size().width, y: baseline))
        NSGraphicsContext.restoreGraphicsState()
    }
    for (anchor, point) in anchors[number - 1] ?? [:] { context.addDestination(anchor as CFString, at: point) }
    for link in printed.page(at: number - 1)?.annotations ?? [] where link.type == "Link" {
        if let url = link.url ?? (link.action as? PDFActionURL)?.url {
            context.setURL(url as CFURL, for: link.bounds)
        } else if let destination = target(of: link) {
            context.setDestination(name(of: destination) as CFString, for: link.bounds)
        }
    }
    context.endPage()
}

func outlineItem(_ index: Int, children: [[String: Any]] = []) -> [String: Any] {
    let destination = targets[index]
    var item: [String: Any] = [
        kCGPDFOutlineTitle as String: contents[index].1.title,
        kCGPDFOutlineDestination as String: printed.index(for: destination.page!) + 1,
        kCGPDFOutlineDestinationRect as String: CGRect(origin: destination.point, size: .zero).dictionaryRepresentation,
    ]
    if !children.isEmpty { item[kCGPDFOutlineChildren as String] = children }
    return item
}
var chapters: [[String: Any]] = []
var chapterIndex: Int?, sections: [[String: Any]] = []
for index in contents.indices {
    if contents[index].1.level == 1 {
        if let chapterIndex { chapters.append(outlineItem(chapterIndex, children: sections)) }
        chapterIndex = index
        sections = []
    } else {
        sections.append(outlineItem(index))
    }
}
if let chapterIndex { chapters.append(outlineItem(chapterIndex, children: sections)) }
CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: chapters] as CFDictionary)
context.closePDF()
