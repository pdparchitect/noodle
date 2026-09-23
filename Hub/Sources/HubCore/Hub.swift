import Foundation
import NoodleCore
import NoodleRuntime

/// The Hub's bots, harnesses and conversations, kept apart from Noodle's own.
@MainActor public final class Hub {
    public static let folderName = "Noodle Hub"

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
