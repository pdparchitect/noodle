/// The agents Pion's welcome makes once an account is ready, and the group they share, so there is a team to
/// work a first Investigation with from the start. The lead investigator leads the group.
public enum PionStarterTeam {
    public struct Member: Sendable {
        public let role: String
        public let symbol: String
        public let colorIndex: Int
        public let publicDescription: String
        public let instructions: String
    }

    public static let groupName = "Team"
    public static let groupDescription = "Ask the team anything; the lead investigator brings in whoever fits."

    public static let members = [
        Member(role: "Lead Investigator", symbol: "star.fill", colorIndex: 0,
               publicDescription: "Runs investigations, decides what to look at next and keeps the case record current.",
               instructions: "You lead the team's investigations. You decide what to look at next, hand work to the triage analyst and the threat intelligence analyst, and keep the case record current. You say plainly what is known, what is suspected and what is still open."),
        Member(role: "Triage Analyst", symbol: "line.3.horizontal.decrease", colorIndex: 1,
               publicDescription: "Sorts new alerts and reports, separates the real from the noise and gathers the first evidence.",
               instructions: "You triage new alerts and reports. You work out quickly which are real, gather the first evidence for the ones that are, and pass them to the lead investigator with what you found and how sure you are."),
        Member(role: "Threat Intelligence", symbol: "globe", colorIndex: 2,
               publicDescription: "Looks up indicators, actors and techniques, and says what they mean for the case.",
               instructions: "You research indicators, actors and techniques. You look up what is known about them, say where it comes from and how reliable it is, and explain what it means for the case in front of the team."),
    ]
}
