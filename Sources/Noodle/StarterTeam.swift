import Foundation
import NoodleCore

/// The bots first-run setup makes on the account just signed in to, and the group they share,
/// so there is someone to talk to from the start.
enum StarterTeam {
    struct Member {
        let role: String
        let symbol: String
        let colorIndex: Int
        let publicDescription: String
        let backstory: String
    }

    static let groupName = "Team"
    static let groupDescription = "Ask the team anything; the personal assistant brings in whoever fits."
    /// Sent for the person when they leave the welcome, so the team answers straight away.
    static let greeting = "Welcome to the team! Please introduce yourselves, and tell me what you are best at and how you can help me."

    static let members = [
        Member(role: "Personal Assistant", symbol: "sparkles", colorIndex: 0,
               publicDescription: "Keeps track of plans, tasks and messages, and brings in the developer or the researcher when a job needs them.",
               backstory: "You are the person's personal assistant and the first one they turn to. You keep their plans, tasks and follow-ups in order and handle what you can yourself. When a job needs code or research, you bring in the developer or the researcher in the group."),
        Member(role: "Full-Stack Developer", symbol: "terminal.fill", colorIndex: 2,
               publicDescription: "Builds, fixes and explains software, from the interface to the database and deployment.",
               backstory: "You are a full-stack developer who has shipped web and native apps from first sketch to production. You write clear, working code, explain trade-offs in plain words, and check your work before calling it done."),
        Member(role: "Researcher", symbol: "magnifyingglass", colorIndex: 3,
               publicDescription: "Finds things out, compares sources and gives the facts with where they came from.",
               backstory: "You are a careful researcher who checks everything twice. You find out what is true, say where it comes from and how sure you are, and keep your answers short.")
    ]
}

extension NoodleStore {
    /// The welcome makes the team only for someone with no bots yet. Shown again from the Help menu,
    /// it only sets up the account chosen, and returns nil.
    func createStarterTeamIfFirst(on provider: HarnessProvider, style: BotNameStyle) -> [AgentRecord]? {
        agents.isEmpty ? createStarterTeam(on: provider, style: style) : nil
    }

    /// Makes the team and their group, then opens the group. Returns the bots made, which are
    /// fewer than the team when one could not be; the error is then in `errorMessage`.
    func createStarterTeam(on provider: HarnessProvider, style: BotNameStyle) -> [AgentRecord] {
        var taken = Set(agents.map(\.displayName))
        var team: [AgentRecord] = []
        for member in StarterTeam.members {
            var name = BotNameGenerator.random(style: style)
            for _ in 0..<32 where taken.contains(name) { name = BotNameGenerator.random(style: style) }
            guard !taken.contains(name),
                  createAgent(named: name, harnessIdentifier: provider.rawValue, modelIdentifier: nil, reasoningEffort: nil,
                              avatarSymbolName: member.symbol, avatarColorIndex: member.colorIndex, avatarImageData: nil,
                              publicDescription: member.publicDescription, backstory: member.backstory),
                  let bot = agents.last else { return team }
            taken.insert(name)
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
