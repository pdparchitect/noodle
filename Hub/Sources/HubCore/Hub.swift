import Foundation
import NoodleCore
import NoodleRuntime
import Observation

/// The Hub's bots, harnesses and conversations. They live in the Hub's own sandbox
/// container, apart from Noodle's; the folder name is the one the Agent Host looks in.
@MainActor @Observable public final class Hub {
    public static let folderName = "Noodle"

    public let repository: WorkspaceRepository
    public let runtime: AgentRuntimeCoordinator
    /// Where the API listens once started, or why it could not.
    public private(set) var serverPort: UInt16?
    public private(set) var serverError: String?
    @ObservationIgnored private var server: HubServer?

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

    /// Starts the API for paired clients. Only this Mac can reach it for now.
    public func startServer(port: UInt16 = HubServer.defaultPort) async {
        do {
            try repository.prepare()
            let server = HubServer(repository: repository, token: try accessToken())
            serverPort = try await server.start(port: port)
            self.server = server
            serverError = nil
        } catch {
            serverError = error.localizedDescription
        }
    }

    public func stopServer() {
        server?.stop()
        server = nil
        serverPort = nil
    }

    /// The secret a client presents with every request.
    public func accessToken() throws -> String {
        try HubAccessToken.load(root: repository.rootURL)
    }

    /// Harnesses found on this Mac that bots can use.
    public var harnesses: [HarnessInstallation] { runtime.installations.filter(\.isAvailable) }
}
