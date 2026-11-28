import Foundation

/// Who hears a person's new message in a group first: the lead, and any bot the message names with an
/// @mention, straight away; the others a few seconds later, so they read what the lead did before replying.
public enum GroupLead {
    /// How long the others wait.
    public static let headStart: Duration = .seconds(3)

    /// The participants split into those woken now and those woken after the head start. Everyone is woken
    /// now in a group without a lead, and in direct conversations.
    public static func wakeOrder(_ participants: [AgentRecord], in conversation: BotConversation,
                                 body: String) -> (now: [AgentRecord], later: [AgentRecord]) {
        guard let lead = conversation.lead, participants.contains(where: { $0.id == lead }) else {
            return (participants, [])
        }
        let named = mentioned(in: body, among: participants)
        let now = participants.filter { $0.id == lead || named.contains($0.id) }
        let later = participants.filter { $0.id != lead && !named.contains($0.id) }
        return (now, later)
    }

    public static func interruptionTargets(_ agents: [AgentRecord], in conversation: BotConversation,
                                           body: String) -> Set<UUID> {
        if conversation.kind == .group { return mentioned(in: body, among: agents) }
        return Set(agents.map(\.id))
    }

    /// The bots the text names as @Name, the whole name followed by anything but a letter or digit.
    public static func mentioned(in text: String, among agents: [AgentRecord]) -> Set<UUID> {
        Set(agents.filter { agent in
            let name = agent.displayName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return false }
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: "@" + name, options: [.caseInsensitive], range: searchRange) {
                if found.upperBound == text.endIndex { return true }
                let next = text[found.upperBound]
                if !(next.isLetter || next.isNumber) { return true }
                searchRange = found.upperBound..<text.endIndex
            }
            return false
        }.map(\.id))
    }
}
