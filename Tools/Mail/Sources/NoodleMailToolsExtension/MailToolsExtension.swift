import ExtensionFoundation
import Foundation
import NoodleCore
import NoodleMailTools

/// Holds the Mail group so the rest of the tool framework does not need it.
@main
struct MailToolsExtension: AppExtension {
    var configuration: some AppExtensionConfiguration { MailToolsConfiguration() }
}

struct MailToolsConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        ToolExtensionService(provider: MailToolProvider.live()).accept(connection)
    }
}
