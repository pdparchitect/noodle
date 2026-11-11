import Foundation

/// How Noodle, Noodle Mobile and Noodle Hub search, so every device finds the same things: bots and groups by
/// name first, then each message that says the term. Case and accents never matter.
public struct ConversationSearch: Equatable, Sendable {
    public let term: String

    /// Nil for a blank search, which shows the list as it is.
    public init?(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        self.term = term
    }

    public func matches(_ text: String) -> Bool { range(in: text) != nil }

    /// Every place the term is in `text`, to set it in bold.
    public func ranges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = [], start = text.startIndex
        while let match = range(in: text, from: start) {
            found.append(match)
            start = match.upperBound
        }
        return found
    }

    #if canImport(Darwin)
    /// `text` with the term in bold wherever it is, as a snippet shows it.
    public func highlighted(_ text: String) -> AttributedString {
        var styled = AttributedString(text)
        for match in ranges(in: text) {
            guard let range = Range(match, in: styled) else { continue }
            styled[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return styled
    }
    #endif

    private func range(in text: String, from start: String.Index? = nil) -> Range<String.Index>? {
        let start = start ?? text.startIndex
        guard start < text.endIndex else { return nil }
        return text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex, locale: .current)
    }

    // MARK: Bots and groups

    /// A bot or group as the search sees it.
    public struct Candidate<ID: Hashable> {
        public var id: ID
        public var isGroup: Bool
        public var name: String
        public var about: String
        /// The names of a group's bots; a group with Blake in it is found by searching for Blake.
        public var members: [String]

        public init(id: ID, isGroup: Bool, name: String, about: String, members: [String] = []) {
            self.id = id
            self.isGroup = isGroup
            self.name = name
            self.about = about
            self.members = members
        }
    }

    public struct Sections<ID: Hashable> {
        public var bots: [ID] = []
        public var groups: [ID] = []

        public var isEmpty: Bool { bots.isEmpty && groups.isEmpty }
    }

    /// The bots and groups that match, in the order given within each kind of match: by name first, then by
    /// description, then, for groups, by a bot in them.
    public func sections<ID>(_ candidates: [Candidate<ID>]) -> Sections<ID> {
        func rank(_ candidate: Candidate<ID>) -> Int? {
            if matches(candidate.name) { return 0 }
            if matches(candidate.about) { return 1 }
            if candidate.isGroup, candidate.members.contains(where: matches) { return 2 }
            return nil
        }
        let ranked = candidates.enumerated().compactMap { index, candidate in rank(candidate).map { (candidate, $0, index) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        var sections = Sections<ID>()
        for (candidate, _, _) in ranked {
            if candidate.isGroup { sections.groups.append(candidate.id) } else { sections.bots.append(candidate.id) }
        }
        return sections
    }

    // MARK: Messages

    /// About two lines of a sidebar row.
    public static let snippetLength = 100
    /// How much of what comes before the term a snippet keeps.
    private static let snippetLead = 30
    /// When the term also names a bot or group, the person most likely wants that one, so only the newest
    /// mentions show until they ask for all.
    public static let mentionsBesideNames = 3

    /// The text around the first match on one line, cut at words with an ellipsis where it was cut; nil
    /// without a match. `text` is what the message shows, without its markdown.
    public func snippet(of text: String) -> String? {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let match = range(in: line) else { return nil }
        var start = line.index(match.lowerBound, offsetBy: -Self.snippetLead, limitedBy: line.startIndex) ?? line.startIndex
        if start > line.startIndex, let space = line[start..<match.lowerBound].firstIndex(of: " ") {
            start = line.index(after: space)
        }
        var end = max(line.index(start, offsetBy: Self.snippetLength, limitedBy: line.endIndex) ?? line.endIndex, match.upperBound)
        if end < line.endIndex, let space = line[match.upperBound..<end].lastIndex(of: " ") { end = space }
        return (start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : "")
    }

    /// Each message that says the term, newest first, at most `limit`. `read` gives a message's ID, when it
    /// was said and its text, or nil text for one the search leaves out, such as the app's own notices.
    public func messageMatches<Message>(in conversations: [(id: UUID, messages: [Message])], limit: Int,
                                        read: (Message) -> (id: UUID, date: Date, text: String?)) -> [LinkMessageMatch] {
        var found: [LinkMessageMatch] = []
        for conversation in conversations {
            if Task.isCancelled { return [] }
            for message in conversation.messages {
                let (id, date, text) = read(message)
                guard let text, let snippet = snippet(of: text) else { continue }
                found.append(LinkMessageMatch(conversationID: conversation.id, messageID: id, createdAt: date, snippet: snippet))
            }
        }
        // Said at the same moment, the later one in its conversation comes first.
        let newestFirst = found.enumerated().sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }
        return Array(newestFirst.prefix(max(0, limit)).map(\.element))
    }

    /// The mentions to list, and how many more Show All would add.
    public func shown<T>(_ matches: [T], besideNames: Bool, showingAll: Bool) -> (shown: [T], hidden: Int) {
        guard besideNames, !showingAll, matches.count > Self.mentionsBesideNames else { return (matches, 0) }
        return (Array(matches.prefix(Self.mentionsBesideNames)), matches.count - Self.mentionsBesideNames)
    }
}

/// A message that says what was searched for, with the text around it.
public struct LinkMessageMatch: Codable, Equatable, Hashable, Sendable {
    public var conversationID: UUID
    public var messageID: UUID
    public var createdAt: Date
    public var snippet: String

    public init(conversationID: UUID, messageID: UUID, createdAt: Date, snippet: String) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.createdAt = createdAt
        self.snippet = snippet
    }
}

/// What to search a Hub's conversations for, answered with `messageMatches`.
public struct LinkMessageSearch: Codable, Equatable, Sendable {
    public var term: String
    public var limit: Int

    public init(term: String, limit: Int = LinkMessageSearch.standardLimit) {
        self.term = term
        self.limit = limit
    }

    public static let standardLimit = 200
    /// The most a Hub answers with, whatever was asked.
    public static let maximumLimit = 500
}
