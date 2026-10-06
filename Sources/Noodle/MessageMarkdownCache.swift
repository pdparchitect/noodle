import Foundation
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
        let value: [Segment]
        init(body: String, value: [Segment]) { self.body = body; self.value = value }
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

    func segments(_ message: ChatMessage) -> [Segment] {
        let key = message.id as NSUUID
        if let cached = segmentValues.object(forKey: key), cached.body == message.body { return cached.value }
        let parts = MessageSegment.split(message.body)
        let segments: [Segment] = parts.contains(where: { if case .table = $0 { true } else { false } })
            ? parts.map {
                switch $0 {
                case .text(let text): .text(Self.render(text), source: text)
                case .table(let table): .table(table)
                }
            }
            : [.text(render(message), source: message.body)]
        segmentValues.setObject(SegmentsBox(body: message.body, value: segments), forKey: key)
        return segments
    }

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
        return rendered
    }
}
