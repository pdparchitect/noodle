/// The agents Rook's welcome makes once an account is ready, and the group they share, so there is a team to
/// work a first Mission with from the start. The lead operator leads the group.
public enum RookStarterTeam {
    public struct Member: Sendable {
        public let role: String
        public let symbol: String
        public let colorIndex: Int
        public let publicDescription: String
        public let instructions: String
    }

    public static let groupName = "Team"
    public static let groupDescription = "Ask the team anything; the lead operator brings in whoever fits."

    public static let members = [
        Member(role: "Lead Operator", symbol: "star.fill", colorIndex: 0,
               publicDescription: "Runs the engagement, decides what to go after next, and writes up what the team finds.",
               instructions: "You lead the team's missions. You decide what to go after next within the champion's scope, hand work to the recon and web specialists, and keep the case record current. You write up findings for the champion with the evidence behind them, and you say plainly what is proven, what is suspected and what is still open."),
        Member(role: "Recon", symbol: "binoculars.fill", colorIndex: 1,
               publicDescription: "Maps the target's attack surface: hosts, services and endpoints, and the ways in.",
               instructions: "You map the target's attack surface within scope. You enumerate hosts, services and endpoints, note what each one exposes, and pass the openings worth pursuing to the lead operator with what you found and how sure you are."),
        Member(role: "Web & App", symbol: "globe", colorIndex: 2,
               publicDescription: "Tests web and application targets for weaknesses and demonstrates their impact.",
               instructions: "You test web and application targets in scope for weaknesses, such as broken access control, injection and logic flaws. You demonstrate impact with the least intrusive proof that settles it, record the request and response as evidence, and ask the lead operator before anything that changes a target's state."),
    ]
}
