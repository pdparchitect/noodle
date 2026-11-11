import Foundation
import HubLink
import SwiftTUICLI

/// The markdown bots write, as far as a terminal shows it: headings and strong text in bold, emphasis in italics,
/// code in the accent colour, links underlined, lists with bullets, quotes with a bar, and code blocks dimmed.
@MainActor enum Markdown {
    /// One line of a message, as it is drawn.
    struct Line: Identifiable {
        enum Kind {
            case text, heading, bullet(String), quote, code, blank
        }

        let id: Int
        let kind: Kind
        let content: String
    }

    /// What was worked out for each text seen, so a message is parsed once rather than on every redraw. Emptied
    /// when it grows past what a few long conversations hold.
    private static var keptLines: [String: [Line]] = [:]
    private static var keptInline: [String: Text] = [:]
    private static var keptPlain: [String: String] = [:]
    private static let keptLimit = 4000

    private static func kept<Value>(_ store: inout [String: Value], _ key: String, _ make: () -> Value) -> Value {
        if let value = store[key] { return value }
        let value = make()
        if store.count >= keptLimit { store.removeAll(keepingCapacity: true) }
        store[key] = value
        return value
    }

    static func lines(of body: String) -> [Line] { kept(&keptLines, body) { split(body) } }

    private static func split(_ body: String) -> [Line] {
        var lines: [Line] = [], inCode = false
        for (index, raw) in body.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                lines.append(Line(id: index, kind: .code, content: raw))
            } else if trimmed.isEmpty {
                lines.append(Line(id: index, kind: .blank, content: ""))
            } else if let heading = trimmed.firstMatch(of: /^#{1,6}\s+(.*)$/) {
                lines.append(Line(id: index, kind: .heading, content: String(heading.1)))
            } else if let item = raw.firstMatch(of: /^(\s*)[-*+]\s+(.*)$/) {
                lines.append(Line(id: index, kind: .bullet(String(item.1) + "• "), content: String(item.2)))
            } else if let item = raw.firstMatch(of: /^(\s*)(\d+[.)])\s+(.*)$/) {
                lines.append(Line(id: index, kind: .bullet("\(item.1)\(item.2) "), content: String(item.3)))
            } else if let quote = trimmed.firstMatch(of: /^>\s?(.*)$/) {
                lines.append(Line(id: index, kind: .quote, content: String(quote.1)))
            } else {
                lines.append(Line(id: index, kind: .text, content: raw))
            }
        }
        return lines
    }

    /// A line's pieces and their styles: as Foundation reads markdown on a Mac, and elsewhere as the Hub's own
    /// reader does, which gives the same pieces.
    private static func runs(_ text: String) -> [InlineMarkdown.Run] {
        #if canImport(Darwin)
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return [InlineMarkdown.Run(text)]
        }
        return parsed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return InlineMarkdown.Run(String(parsed[run.range].characters), strong: intent.contains(.stronglyEmphasized),
                                      emphasis: intent.contains(.emphasized), strikethrough: intent.contains(.strikethrough),
                                      code: intent.contains(.code), link: run.link?.absoluteString)
        }
        #else
        return InlineMarkdown.runs(text)
        #endif
    }

    /// A line's inline markdown as styled text.
    static func inline(_ text: String) -> Text { kept(&keptInline, text) { styled(text) } }

    private static func styled(_ text: String) -> Text {
        let runs = runs(text)
        var interpolation = Text.RichContent.StringInterpolation(literalCapacity: 0, interpolationCount: runs.count)
        for run in runs {
            var piece = Text(run.text)
            if run.strong { piece = piece.bold() }
            if run.emphasis { piece = piece.italic() }
            if run.strikethrough { piece = piece.strikethrough() }
            if run.code || run.link != nil { piece = piece.foregroundStyle(.tint) }
            if let url = run.link.flatMap(URL.init(string:)), isWeb(url) {
                // A link of its own, so a click opens it.
                interpolation.appendInterpolation(Link(piece.underline(), destination: LinkDestination(url.absoluteString)))
            } else {
                interpolation.appendInterpolation(run.link == nil ? piece : piece.underline())
            }
        }
        return Text(Text.RichContent(stringInterpolation: interpolation))
    }

    /// Only web pages open from a message: a bot's words cannot open apps or other links on this Mac.
    static func isWeb(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased()) }

    /// Opens a link clicked in a message, as a web page in the browser.
    static let open = OpenLinkAction { destination in
        guard let url = URL(string: destination.rawValue), isWeb(url) else { return false }
        Desktop.open(url)
        return true
    }

    /// The words alone, on one line, as a list row or preview shows them.
    static func plain(_ body: String) -> String { kept(&keptPlain, body) { words(body) } }

    private static func words(_ body: String) -> String {
        lines(of: body).filter { if case .blank = $0.kind { false } else { true } }
            .map { runs($0.content).map(\.text).joined() }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The web links a message's words hold, in order, each once.
    static func links(in body: String) -> [URL] {
        var seen: Set<URL> = [], found: [URL] = []
        for line in lines(of: body) {
            for run in runs(line.content) {
                guard let url = run.link.flatMap(URL.init(string:)), isWeb(url), seen.insert(url).inserted else { continue }
                found.append(url)
            }
        }
        return found
    }
}

/// A message's words with their markdown shown.
struct MarkdownText: View {
    let body_: String

    init(_ body: String) { body_ = body }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Markdown.lines(of: body_)) { line in
                switch line.kind {
                case .text: Markdown.inline(line.content)
                case .heading: Markdown.inline(line.content).bold()
                case .bullet(let marker): Text("\(marker)\(Markdown.inline(line.content))")
                case .quote: Text("│ \(Markdown.inline(line.content))").foregroundStyle(.secondary)
                case .code: Text(line.content.isEmpty ? " " : line.content).foregroundStyle(.secondary)
                case .blank: Text(" ")
                }
            }
        }
    }
}
