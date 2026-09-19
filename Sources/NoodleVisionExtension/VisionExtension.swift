import ExtensionFoundation
import Foundation
import NoodleCore
import NoodleVisionTools

/// A tool extension is a provider plus this shell. The system starts it on demand
/// in its own sandbox and stops it when idle.
@main
struct VisionExtension: AppExtension {
    var configuration: some AppExtensionConfiguration { ToolExtensionConfiguration() }
}

struct ToolExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        ToolExtensionService(provider: VisionToolProvider()).accept(connection)
    }
}
