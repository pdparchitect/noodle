import Foundation

/// Built-in advice for situations a bot cannot resolve from its other skills.
/// Every tip is rendered into the managed `tips` skill; the skill description
/// is what makes a bot open it, so it names the situations the tips cover.
public struct AgentTip: Equatable, Sendable {
    public let id: String
    public let title: String
    public let advice: String
}

public enum AgentTips {
    public static let all: [AgentTip] = [
        AgentTip(
            id: "sandbox-blocked",
            title: "Blocked by the sandbox",
            advice: """
            When a command, file operation, install or network request fails with "Operation not permitted", "Permission denied" or a sandbox denial, do not retry it another way and do not try to get around the sandbox. If the `computer` skill is available, do the work in an assigned computer instead. Otherwise tell the user through Messenger what you were trying to do and ask them to assign you a computer in Edit Bot → Computers, then continue there once it is assigned.
            """),
        AgentTip(
            id: "connection-sign-in",
            title: "A tool connection needs sign-in or consent",
            advice: """
            When a connection skill reports that sign-in, authorization or additional consent is needed, do not launch a login flow and do not retry. Tell the user through Messenger which connection it is, named in that skill, and ask them to reconnect it in Settings → Tools. Continue once they confirm.
            """),
    ]

    /// The only recovery advice other generated guidance gives: the advice itself lives in the tips.
    public static let reference = "When you are blocked, read the `tips` skill before giving up or telling the user what to change."

    public static var skill: String {
        """
        ---
        name: tips
        description: What to do when you are blocked. Read before giving up or telling the user something is impossible, when an operation is denied by the sandbox or permissions, a tool connection needs sign-in, or a capability is missing.
        ---

        # Tips

        \(all.map { "## \($0.title)\n\n\($0.advice)" }.joined(separator: "\n\n"))

        """
    }

    /// A user skill that already owns the name is kept.
    public static func synchronize(workspace: URL) throws {
        do {
            try WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: "tips", enabled: true,
                instructions: skill, command: "", executable: nil)
        } catch is HarnessSetupError {}
    }
}
