import Foundation
import HubLink
import NoodleCore
import NoodleRuntime

/// The Hub's bots, harnesses and conversations. They live in the Hub's own sandbox
/// container, apart from Noodle's; the folder name is the one the Agent Host looks in.
@MainActor public final class Hub {
    public static let folderName = "Noodle"

    public let repository: WorkspaceRepository
    public let runtime: AgentRuntimeCoordinator
    public let harnessProfiles: HarnessProfilesController
    public let usage: UsageHistory
    public let access: HubAccess
    public let link: HubLinkService

    public init(root: URL, messenger: URL?) {
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: messenger)
        // Only the Hub's own storage holds harnesses its Agent Host will trust.
        let discovery = HarnessDiscovery(managedHarnesses: repository.managedHarnesses)
        discovery.removeSupersededManagedHarnesses()
        runtime = AgentRuntimeCoordinator(discovery: discovery)
        harnessProfiles = HarnessProfilesController(store: repository.harnessProfiles)
        usage = UsageHistory(url: root.appendingPathComponent("usage.sqlite"))
        runtime.onUsage = { [usage] in usage.record($0) }
        access = HubAccess(url: root.appendingPathComponent("access.json"))
        link = HubLinkService(hubName: Host.current().localizedName ?? "Noodle Hub",
                              directory: root.appendingPathComponent("Link", isDirectory: true),
                              access: access, profiles: harnessProfiles)
    }

    public static func root(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }
}
