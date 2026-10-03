import NoodleCore
import NoodleRuntime
import SwiftUI

/// What the Harness and Bots settings need from the app that runs bots.
/// Noodle and Noodle Hub each provide it.
@MainActor public protocol BotSettingsHost: AnyObject {
    var runtime: AgentRuntimeCoordinator { get }
    var agents: [AgentRecord] { get }
    var repository: WorkspaceRepository { get }
    var harnessProfiles: HarnessProfilesController { get }
    var mcp: MCPController { get }
    func deleteHarnessProfile(_ profile: HarnessProfile)
    /// Brings the Harness settings forward, for example after a Kick that needs sign-in.
    func showHarnessSettings()
    /// The control a bot's row opens its profile with.
    func botProfileButton(_ agent: AgentRecord) -> AnyView
    /// Whether the bot can be archived from here; the Archived column shows only when one can.
    func canArchive(_ agent: AgentRecord) -> Bool
    func setArchived(_ archived: Bool, agent: AgentRecord)
    /// The editor for a bot's harness and model.
    func botRuntimeEditor(_ agent: AgentRecord) -> AnyView
    /// Rereads the skills companions publish to bots.
    func refreshCompanionSkills()
    /// Opens an installed companion's library.
    func openCompanionLibrary(_ app: CompanionApp) async throws
}
