import Foundation
import HubWire
import NoodleCore

/// What was said, found for the sidebar's search in every app: once typing pauses, off the main thread, and a newer
/// search cancels this one.
@MainActor @Observable public final class MentionFinder {
    private var found: (term: String, matches: [LinkMessageMatch])?
    @ObservationIgnored public private(set) var task: Task<Void, Never>?
    /// How long typing pauses before what was said is searched.
    @ObservationIgnored public var delay: Duration = .milliseconds(250)

    public init() {}

    /// Searches `conversations` for `search`, or forgets what was found when nothing is searched for.
    public func find(_ search: ConversationSearch?, in conversations: [(id: UUID, messages: [ChatMessage])]) {
        task?.cancel()
        guard let search else {
            found = nil
            task = nil
            return
        }
        let delay = delay
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                search.messageMatches(in: conversations)
            }.value
            guard !Task.isCancelled else { return }
            self?.found = (search.term, matches)
        }
    }

    /// Each message that says the term, or nil while they are still being found.
    public func matches(for search: ConversationSearch) -> [LinkMessageMatch]? {
        guard let found, found.term == search.term else { return nil }
        return found.matches
    }
}
