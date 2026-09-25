import ExtensionFoundation
import Foundation
import NoodleCore
import NoodleMapsTools

/// A tool extension is a provider plus this shell. The system starts it on demand
/// in its own sandbox and stops it when idle.
@main
struct MapsToolsExtension: AppExtension {
    var configuration: some AppExtensionConfiguration { MapsToolsConfiguration() }
}

struct MapsToolsConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        ToolExtensionService(provider: MapsToolProvider()).accept(connection)
    }
}
