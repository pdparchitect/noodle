import HubLink
import NoodleCore
import SwiftUI

/// Prepared message content, independent of hover, scroll geometry and other row state.
@MainActor final class MessageBodyRenderer {
    static let shared = MessageBodyRenderer()

    /// Noodle's blocks, so both apps split a message into the same paragraphs, lists and code.
    typealias Block = MessageBlock
    typealias ListItem = MessageListItem

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

    private static func blocks(_ text: String) -> [Block] { MessageMarkdownCache.blocks(text) }
}
