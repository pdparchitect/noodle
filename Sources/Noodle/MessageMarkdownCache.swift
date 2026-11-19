import Foundation
import SwiftUI
import NoodleCore
import NoodleRuntimeSettings
import HubLink

// Shared by chat messages and the isolated native Markdown fixture.
final class MessageMarkdownCache: @unchecked Sendable {
    static let shared = MessageMarkdownCache()

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// A message's parts in order: prose with its rendered text, and tables.
    enum Segment {
        case text(AttributedString, source: String)
        case table(MessageTable)
    }

    private final class SegmentsBox {
        let body: String
        let layout: MessageTextLayout
        let value: [Segment]
        init(body: String, layout: MessageTextLayout, value: [Segment]) {
            self.body = body; self.layout = layout; self.value = value
        }
    }

    private let values = NSCache<NSUUID, Box>()
    private let segmentValues = NSCache<NSUUID, SegmentsBox>()

    private init() {
        values.countLimit = 1_000
        segmentValues.countLimit = 1_000
    }

    func render(_ message: ChatMessage) -> AttributedString {
        let key = message.id as NSUUID
        if let cached = values.object(forKey: key) { return cached.value }
        let rendered = Self.render(message.body)
        values.setObject(Box(rendered), forKey: key)
        return rendered
    }

    func segments(_ message: ChatMessage, layout: MessageTextLayout = .defaultValue) -> [Segment] {
        let key = message.id as NSUUID
        if let cached = segmentValues.object(forKey: key), cached.body == message.body, cached.layout == layout {
            return cached.value
        }
        let parts = MessageSegment.split(message.body, layout: layout)
        let segments: [Segment] = parts.count > 1 || parts.contains(where: { if case .table = $0 { true } else { false } })
            ? parts.map {
                switch $0 {
                case .text(let text): .text(Self.render(text), source: text)
                case .table(let table): .table(table)
                }
            }
            : [.text(render(message), source: message.body)]
        segmentValues.setObject(SegmentsBox(body: message.body, layout: layout, value: segments), forKey: key)
        return segments
    }

    /// Links take the accent, as the buttons and selections around them do: the same colour link buttons have.
    static let linkColor = AccentLink.color

    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let text = boldHeadings(text)
        var rendered = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        let allowedSchemes = Set(["http", "https", "mailto"])
        let unsafeLinkRanges = rendered.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link,
                  !allowedSchemes.contains(link.scheme?.lowercased() ?? "") else { return nil }
            return run.range
        }
        for range in unsafeLinkRanges { rendered[range].link = nil }
        let linkRanges = rendered.runs.compactMap { run in run.link != nil ? run.range : nil }
        for range in linkRanges { rendered[range].foregroundColor = linkColor }
        // Mono at the 12.5 pt body size looks larger and heavier than the prose around it.
        let codeRanges = rendered.runs.compactMap { run in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            rendered[range].font = .system(size: 11.5, design: .monospaced)
            rendered[range].foregroundColor = .primary.opacity(0.65)
        }
        return rendered
    }
}

/// One stretch of a message's prose, laid out on its own: paragraphs, lists and code each a block, so the space
/// between any two is the same.
enum MessageBlock {
    case text(AttributedString)
    case code(String)
    /// Lines begun with "- ", "* ", "• " or a number, so wrapped lines can hang under the text, not the marker.
    case list([MessageListItem])
}

struct MessageListItem {
    /// A bullet, or the item's number written as "1.".
    let marker: String
    let text: AttributedString
}

extension MessageMarkdownCache {
    private final class BlocksBox {
        let value: [MessageBlock]
        init(_ value: [MessageBlock]) { self.value = value }
    }
    nonisolated(unsafe) private static let blockCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 1_000
        return cache
    }()

    /// `text` as blocks, kept so a redrawn message is not split again.
    func blocks(_ text: String) -> [MessageBlock] {
        if let cached = Self.blockCache.object(forKey: text as NSString) { return cached.value }
        let blocks = Self.blocks(text)
        Self.blockCache.setObject(BlocksBox(blocks), forKey: text as NSString)
        return blocks
    }

    /// Code, paragraphs and lists, each a block of its own: a blank line between paragraphs, the start of a list and its
    /// end all read as one step.
    static func blocks(_ text: String) -> [MessageBlock] {
        var result: [MessageBlock] = [], lines: [Substring] = [], items: [MessageListItem] = [], inCode = false
        func flushText() {
            let joined = lines.joined(separator: "\n")
            if inCode { result.append(.code(joined)) }
            else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(render(joined.trimmingCharacters(in: .newlines))))
            }
            lines = []
        }
        func flushList() {
            if !items.isEmpty { result.append(.list(items)) }
            items = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushList(); flushText(); inCode.toggle()
            } else if inCode {
                lines.append(line)
            } else if trimmed.isEmpty {
                flushList(); flushText()
            } else if let item = listItem(trimmed) {
                flushText(); items.append(item)
            } else {
                flushList(); lines.append(line)
            }
        }
        flushList(); flushText()
        return result
    }

    /// A line that starts a list item: a dash, star or bullet, or a number followed by "." or ")", then a space.
    private static func listItem(_ line: String) -> MessageListItem? {
        if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : MessageListItem(marker: "•", text: render(rest))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = line.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        let rest = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : MessageListItem(marker: digits + ".", text: render(rest))
    }

    /// Markdown headings as bold lines of their own, rather than large type that breaks a conversation's flow. A "#"
    /// with no space after it, as in a hashtag, stays as written, and nothing changes inside code.
    static func boldHeadings(_ text: String) -> String {
        guard text.contains("#") else { return text }
        var inCode = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); return String(line) }
            let hashes = trimmed.prefix { $0 == "#" }
            guard !inCode, (1...6).contains(hashes.count), trimmed.dropFirst(hashes.count).first == " " else { return String(line) }
            var title = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
            // A closing run of hashes, as "## Title ##", is part of the syntax too.
            while title.hasSuffix("#") { title.removeLast() }
            title = title.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? String(line) : "**\(title)**"
        }.joined(separator: "\n")
    }
}

extension MessageTextLayout {
    static let defaultsKey = "messageTextLayout"
    static let defaultValue = Self.together

    var displayName: String {
        switch self {
        case .together: "Together"
        case .paragraphs: "Paragraphs"
        case .chunks: "Chunks"
        }
    }

    var explanation: String {
        switch self {
        case .together: "Show each message in one bubble."
        case .paragraphs: "Start a new bubble at every blank line."
        case .chunks: "Group paragraphs into short bubbles, keeping a line that ends in a colon with what follows."
        }
    }
}
