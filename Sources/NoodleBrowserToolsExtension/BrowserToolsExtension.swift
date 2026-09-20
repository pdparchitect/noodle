import ExtensionFoundation
import Foundation
import NoodleBrowserTools
import NoodleCore

/// Holds the browsers group so the rest of the tool framework does not need it.
@main
struct BrowserToolsExtension: AppExtension {
    var configuration: some AppExtensionConfiguration { BrowserToolsConfiguration() }
}

struct BrowserToolsConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        ToolExtensionService(provider: BrowserToolProvider.live()).accept(connection)
    }
}
