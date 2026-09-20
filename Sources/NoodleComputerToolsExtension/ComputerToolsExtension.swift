import ExtensionFoundation
import Foundation
import NoodleComputerTools
import NoodleCore

/// Holds the computers group so the rest of the tool framework does not need it.
@main
struct ComputerToolsExtension: AppExtension {
    var configuration: some AppExtensionConfiguration { ComputerToolsConfiguration() }
}

struct ComputerToolsConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        ToolExtensionService(provider: ComputerToolProvider.live()).accept(connection)
    }
}
