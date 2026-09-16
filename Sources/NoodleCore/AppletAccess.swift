import AppKit
import AppletBridge
import Foundation

public enum AppletAgentSkill {
    public static var instructions: String { MessengerDocumentation.appletSkill(for: .current) }

    public static func installedApplicationURL() -> URL? {
        AppletApplication.locate()
    }

    public static func isCompanionInstalled(at applicationURL: URL?) -> Bool {
        AppletApplication.isInstalled(at: applicationURL)
    }

    public static func synchronize(workspace: URL, enabled: Bool, executable: URL?) throws {
        try WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: "applet", enabled: enabled,
            instructions: instructions, command: "noodlet", executable: executable)
    }
    public static func bridge(workspace: URL) throws -> URL {
        try WorkspaceMailbox(workspace: workspace, path: ".noodle/applet-bridge", create: true).url
    }
}
