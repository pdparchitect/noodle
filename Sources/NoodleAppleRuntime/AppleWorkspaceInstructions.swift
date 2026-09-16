import Foundation
import NoodleCore

enum AppleWorkspaceInstructions {
    static func text(workspace: URL) throws -> String {
        // Reload the canonical file on every wake, including resumed sessions,
        // so backstory and skill assignments cannot drift from the workspace.
        let instructions: String
        do {
            let files = try WorkspaceMailbox(workspace: workspace, path: "")
            let data = try files.read("AGENTS.md", limit: 4 * 1_048_576)
            instructions = String(decoding: data, as: UTF8.self)
        } catch {
            throw HarnessSetupError("Could not load AGENTS.md from the bot workspace: \(error.localizedDescription)")
        }
        return "Working directory: \(workspace.path)\n\nAGENTS.md:\n" + instructions
            + (try AppleSkillCatalog.text(workspace: workspace))
    }
}
