import Foundation
import NoodleBrand
import NoodleCore

extension NoodleStore {
    /// The welcome makes the team only for someone with no bots yet. Shown again from the Help menu,
    /// it only sets up the account chosen, and returns nil.
    func createStarterTeamIfFirst(on provider: HarnessProvider, style: BotNameStyle) -> [AgentRecord]? {
        agents.isEmpty ? createStarterTeam(on: provider, style: style) : nil
    }

    /// Makes the team and their group, then opens the group. Returns the bots made, which are
    /// fewer than the team when one could not be; the error is then in `errorMessage`.
    func createStarterTeam(on provider: HarnessProvider, style: BotNameStyle) -> [AgentRecord] {
        var team: [AgentRecord] = []
        for (member, name) in zip(StarterTeam.members, StarterTeam.names(style: style, avoiding: Set(agents.map(\.displayName)))) {
            guard createAgent(named: name, harnessIdentifier: provider.rawValue, modelIdentifier: nil, reasoningEffort: nil,
                              avatarSymbolName: member.symbol, avatarColorIndex: member.colorIndex, avatarImageData: nil,
                              publicDescription: member.publicDescription, backstory: member.backstory),
                  let bot = agents.last else { return team }
            team.append(bot)
        }
        _ = createGroup(named: StarterTeam.groupName, publicDescription: StarterTeam.groupDescription,
                        participantIDs: Set(team.map(\.id)))
        return team
    }

    /// Opens the team's group with the person's first message to them.
    func greetStarterTeam(in groupID: UUID) {
        selectedConversationID = groupID
        setDraft(StarterTeam.greeting, for: groupID)
        sendDraft(to: groupID)
    }
}
