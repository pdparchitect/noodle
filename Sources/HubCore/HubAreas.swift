import AppletBridge
import Foundation
import HubLink
import NoodleCore

// What the Hub's bots and its link need from the areas a Hub may or may not have. A Hub without one
// leaves it nil: its requests are refused and its bots go without, as on a Hub that never kept it.

/// Something a bot started and then left unused, which the bot is asked to close.
public struct HubIdleNotice: Equatable, Sendable {
    /// Nil when no bot started it.
    public var agentID: UUID?
    public var note: String

    public init(agentID: UUID?, note: String) {
        self.agentID = agentID
        self.note = note
    }
}

/// The computers a Hub keeps for its users, which reach a bot only when assigned to it.
@MainActor public protocol HubComputing: AnyObject {
    var onAssignmentsChange: (() -> Void)? { get set }
    func refresh() async
    func link(for user: HubUser) -> [LinkComputer]
    func linkTemplates(for user: HubUser) async throws -> [LinkComputerTemplate]
    func create(_ draft: LinkComputerDraft, for user: HubUser) async throws -> LinkComputer
    func update(_ id: UUID, with draft: LinkComputerDraft, for user: HubUser) async throws -> LinkComputer
    func delete(_ id: UUID, for user: HubUser) async throws
    func assign(_ ids: Set<UUID>, to bot: UUID, for user: HubUser) throws
    /// Whether the computer is one of the user's.
    func keeps(_ computer: UUID, for user: HubUser) -> Bool
    func openSurface(computer: UUID, terminal: UUID?, bot: UUID, for user: HubUser) async throws -> SurfaceSocket
    func idleNotices() async -> [HubIdleNotice]
    func revoke(computer: UUID, agent: UUID)
    func forget(bot: UUID)
    func synchronizeOwners() async
    func removeComputers(of user: HubUser)
    func reloadAssignments() throws
}

/// The browsers a Hub keeps for its users, which reach a bot only when assigned to it.
@MainActor public protocol HubBrowsing: AnyObject {
    var onAssignmentsChange: (() -> Void)? { get set }
    func refresh() async
    func link(for user: HubUser) -> [LinkBrowser]
    func create(_ draft: LinkBrowserDraft, for user: HubUser) async throws -> LinkBrowser
    func update(_ id: UUID, with draft: LinkBrowserDraft, for user: HubUser) async throws -> LinkBrowser
    func delete(_ id: UUID, for user: HubUser) async throws
    func assign(_ ids: Set<UUID>, to bot: UUID, for user: HubUser) throws
    /// Whether the browser is one of the user's.
    func keeps(_ browser: UUID, for user: HubUser) -> Bool
    func openSurface(browser: UUID, tab: UUID, for user: HubUser) async throws -> SurfaceSocket
    func signInForm(browser: UUID, for user: HubUser) async throws -> LinkSignInForm
    func fillSignIn(_ fill: LinkSignInFill, browser: UUID, for user: HubUser) async throws
    func idleNotices() async -> [HubIdleNotice]
    func forget(bot: UUID)
    func synchronizeOwners() async
    func removeBrowsers(of user: HubUser)
    func reloadAssignments() throws
}

/// Noodle Applet, which runs the noodlets bots share: for the applet tool, for cards and live views,
/// and for the noodlets people's devices run.
@MainActor public protocol HubNoodletRunning: AnyObject {
    /// The bots that may use the applet tool; none stops handing it out.
    func start(agents: [AgentRecord])
    func hasPreview(_ url: URL) async -> Bool
    func companion(_ request: AppletRequest) async throws -> AppletResponse
    func companionSurface(_ request: AppletRequest) async throws -> SurfaceSocket
}
