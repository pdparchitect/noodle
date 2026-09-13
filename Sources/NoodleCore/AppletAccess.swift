import AppKit
import AppletBridge
import Foundation

public enum AppletAgentSkill {
    public static var instructions: String { MessengerDocumentation.appletSkill }

    public static func installedApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppletConnection.providerID)
    }

    public static func isCompanionInstalled(at applicationURL: URL?) -> Bool {
        guard let applicationURL else { return false }
        let application = applicationURL.resolvingSymlinksInPath()
        guard !application.pathComponents.contains(".Trash"),
              !application.pathComponents.contains(".Trashes"),
              let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == AppletConnection.providerID,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".."
        else { return false }
        // Launch Services can retain a registration after an app has been removed.
        return FileManager.default.isExecutableFile(
            atPath: application.appendingPathComponent("Contents/MacOS/\(executable)").path)
    }

    public static func synchronize(workspace: URL, enabled: Bool, executable: URL?) throws {
        try WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: "applet", enabled: enabled,
            instructions: instructions, command: "noodlet", executable: executable)
    }
    public static func bridge(workspace: URL) throws -> URL {
        try WorkspaceMailbox(workspace: workspace, path: ".noodle/applet-bridge", create: true).url
    }
}
