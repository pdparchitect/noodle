import HubLink
import NoodleCore
import SwiftUI

/// Prepared message content, independent of hover, scroll geometry and other row state.
@MainActor final class MessageBodyRenderer {
    static let shared = MessageBodyRenderer()

    enum Block {
        case text(AttributedString)
        case code(String)
        /// Lines an agent began with "- ", "* " or a number, set as a list, so wrapped lines hang under the text.
        case list([ListItem])
    }

    struct ListItem {
        /// A bullet, or the item's number written as "1.".
        let marker: String
        let text: AttributedString
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

    /// Code, paragraphs and lists, each a block of its own, so the space between any two is the same: a blank line
    /// between paragraphs, the start of a list and its end all read as one step.
    private static func blocks(_ text: String) -> [Block] {
        var result: [Block] = [], lines: [Substring] = [], items: [ListItem] = [], inCode = false
        func flushText() {
            let joined = lines.joined(separator: "\n")
            if inCode { result.append(.code(joined)) }
            else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(markdown(joined.trimmingCharacters(in: .newlines))))
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
    private static func listItem(_ line: String) -> ListItem? {
        if let first = line.first, "-*•".contains(first), line.dropFirst().first == " " {
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : ListItem(marker: "•", text: markdown(rest))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = line.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        let rest = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : ListItem(marker: digits + ".", text: markdown(rest))
    }

    /// Noodle's own Markdown, so prose, links and inline code read the same in both apps.
    private static func markdown(_ text: String) -> AttributedString { MessageMarkdownCache.render(text) }
}
