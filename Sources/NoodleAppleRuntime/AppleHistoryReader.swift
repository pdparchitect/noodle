import Foundation

struct AppleHistoryPage {
    let text: String
    let nextOffset: Int?
}

/// A bound on the whole retrieval, in addition to the per-page bound. Repeating
/// a page cannot add information, but would otherwise consume model context.
actor AppleHistoryReader {
    private struct Page: Hashable {
        let offset: Int
        let includeAssistantReplies: Bool
    }
    private var requested: Set<Page> = []
    private var pages: [Page: String] = [:]
    private var nextOffsets: [Bool: Int] = [:]
    private var finishedScopes: Set<Bool> = []
    private var remainingBytes = 6_400

    func read(offset: Int, includeAssistantReplies: Bool,
              fetch: @Sendable () async throws -> AppleHistoryPage) async throws -> String {
        let page = Page(offset: offset, includeAssistantReplies: includeAssistantReplies)
        guard !finishedScopes.contains(includeAssistantReplies),
              offset == nextOffsets[includeAssistantReplies, default: 0],
              requested.count < 4, remainingBytes > 0, requested.insert(page).inserted else {
            throw AppleHistoryLimit()
        }
        let result = try await fetch()
        let text = result.text
        guard text.utf8.count <= remainingBytes else { throw AppleHistoryLimit() }
        remainingBytes -= text.utf8.count
        pages[page] = text
        if let nextOffset = result.nextOffset { nextOffsets[includeAssistantReplies] = nextOffset }
        else { finishedScopes.insert(includeAssistantReplies) }
        return text
    }

    var reference: String {
        pages.keys.sorted {
            if $0.includeAssistantReplies != $1.includeAssistantReplies { return !$0.includeAssistantReplies }
            return $0.offset < $1.offset
        }.compactMap { pages[$0] }.joined(separator: "\n\n")
    }
}

struct AppleHistoryLimit: Error, LocalizedError {
    var errorDescription: String? { "The conversation history retrieval budget is exhausted." }
}
