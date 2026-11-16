import Foundation

/// The bots a first welcome makes, on the Mac or on a phone's first Hub, and the group they share,
/// so there is someone to talk to from the start.
public enum StarterTeam {
    public struct Member: Sendable {
        public let role: String
        public let symbol: String
        public let colorIndex: Int
        public let publicDescription: String
        public let backstory: String
    }

    public static let groupName = "Team"
    public static let groupDescription = "Ask the team anything; the personal assistant brings in whoever fits."

    public static let members = [
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

    /// A name for each member, none of them `taken` nor shared.
    public static func names(style: BotNameStyle, avoiding taken: Set<String>) -> [String] {
        var names: [String] = []
        for _ in members { names.append(BotNameGenerator.random(style: style, avoiding: taken.union(names))) }
        return names
    }

    /// A bundled face for each of `names` that suits the name, none of them `worn` nor shared while any is left.
    public static func faces(for names: [String], avoiding worn: Set<Data>) -> [Data?] {
        var worn = worn
        return names.map { name in
            let face = BotFaces.random(for: BotNameGenerator.presentation(of: name) ?? nil, avoiding: worn)
            if let face { worn.insert(face) }
            return face
        }
    }
}
