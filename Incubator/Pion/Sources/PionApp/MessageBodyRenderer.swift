import HubLink
import NoodleCore
import SwiftUI

/// Prepared message content, independent of hover, scroll geometry and other row state.
@MainActor final class MessageBodyRenderer {
    static let shared = MessageBodyRenderer()

    enum Block {
        case text(AttributedString)
        case code(String)
    }

    enum Segment {
        case prose([Block])
        case table(MessageTable)
    }

    private let prepare: @MainActor (String) -> [Segment]
    private final class PreparedBody {
        let segments: [Segment]
        init(_ segments: [Segment]) { self.segments = segments }
    }
    private let prepared = NSCache<NSString, PreparedBody>()

    init(prepare: @escaping @MainActor (String) -> [Segment] = MessageBodyRenderer.prepare) {
        self.prepare = prepare
        prepared.countLimit = 256
        prepared.totalCostLimit = 8 * 1_024 * 1_024
    }

    func render(_ text: String) -> [Segment] {
        // Key by complete text so edits cannot reuse an older rendering. NSCache lets the
        // system discard old messages under memory pressure without publishing view updates.
        let key = text as NSString
        if let cached = prepared.object(forKey: key) { return cached.segments }
        let segments = prepare(text)
        prepared.setObject(PreparedBody(segments), forKey: key, cost: text.utf8.count * 4)
        return segments
    }

    static func prepare(_ text: String) -> [Segment] {
        MessageSegment.split(text).map { segment in
            switch segment {
            case .text(let prose): .prose(blocks(prose))
            case .table(let table): .table(table)
            }
        }
    }

    private static func blocks(_ text: String) -> [Block] {
        var result: [Block] = [], lines: [Substring] = [], inCode = false
        func flush() {
            let joined = lines.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inCode {
                result.append(inCode ? .code(joined) : .text(markdown(joined.trimmingCharacters(in: .newlines))))
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { flush(); inCode.toggle() } else { lines.append(line) }
        }
        flush()
        return result
    }

    private static func markdown(_ text: String) -> AttributedString {
        var rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                             failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
        // Collect ranges before editing attributes, so changing a run cannot invalidate iteration.
        let unsafeLinks = rendered.runs.compactMap { run in
            run.link.map { ["http", "https", "mailto"].contains($0.scheme?.lowercased() ?? "") } == false ? run.range : nil
        }
        let code = rendered.runs.compactMap { $0.inlinePresentationIntent?.contains(.code) == true ? $0.range : nil }
        for range in unsafeLinks { rendered[range].link = nil }
        for range in code {
            rendered[range].font = .system(size: 12.5, design: .monospaced)
            rendered[range].backgroundColor = Color.secondary.opacity(0.12)
        }
        return rendered
    }
}
