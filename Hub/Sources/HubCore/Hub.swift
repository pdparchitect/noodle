import Foundation
import NoodleCore
import NoodleRuntime

/// The Hub's bots, harnesses and conversations. They live in the Hub's own sandbox
/// container, apart from Noodle's; the folder name is the one the Agent Host looks in.
@MainActor public final class Hub {
    public static let folderName = "Noodle"

    public let repository: WorkspaceRepository
    public let runtime: AgentRuntimeCoordinator

    public init(root: URL, messenger: URL?) {
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: messenger)
        // Only the Hub's own storage holds harnesses its Agent Host will trust.
        let discovery = HarnessDiscovery(managedHarnesses: repository.managedHarnesses)
        discovery.removeSupersededManagedHarnesses()
        runtime = AgentRuntimeCoordinator(discovery: discovery)
    }

    public static func root(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Harnesses found on this Mac that bots can use.
    public var harnesses: [HarnessInstallation] { runtime.installations.filter(\.isAvailable) }
}
