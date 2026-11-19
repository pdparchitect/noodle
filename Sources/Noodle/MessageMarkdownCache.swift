import AppKit
import Foundation
import SwiftUI
import NoodleCore
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

    /// Links take the accent, the app's own or the one the person chose in System Settings, as the buttons and selections
    /// around them do, rather than the system's fixed link blue. In dark appearance it is lightened, as macOS lightens it
    /// for selected controls, so a deep accent still reads as text on a dark window.
    static let linkColor = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return accent }
        return accent.blended(withFraction: 0.4, of: .white) ?? accent
    })

    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
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
