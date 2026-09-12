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
        let directory = workspace.appendingPathComponent(".agents/skills/applet")
        let marker = directory.appendingPathComponent(".noodle-managed")
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path), !manager.fileExists(atPath: marker.path) {
            // Never overwrite a user-authored skill with the same name.
            if enabled { throw AppletError("The applet skill name is occupied by a user skill.") }
            return
        }
        guard enabled else {
            if manager.fileExists(atPath: marker.path) { try manager.removeItem(at: directory) }
            let claudeLink = workspace.appendingPathComponent(".claude/skills/applet")
            if (try? manager.attributesOfItem(atPath: workspace.appendingPathComponent(".claude").path)[.type] as? FileAttributeType) == .typeDirectory,
               (try? manager.attributesOfItem(atPath: claudeLink.deletingLastPathComponent().path)[.type] as? FileAttributeType) == .typeDirectory,
               (try? manager.destinationOfSymbolicLink(atPath: claudeLink.path)) == "../../.agents/skills/applet" {
                try manager.removeItem(at: claudeLink)
            }
            return
        }
        if (try? manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
        {
            throw AppletError("The managed Applet skill must not be a symbolic link.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
        try instructions.write(
            to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        if let executable {
            let link = directory.appendingPathComponent("noodlet")
            if (try? manager.attributesOfItem(atPath: link.path)) != nil {
                try manager.removeItem(at: link)
            }
            try manager.createSymbolicLink(at: link, withDestinationURL: executable)
        }
    }
    public static func bridge(workspace: URL) throws -> URL {
        // Reuse the existing safe-directory and bounded-file primitives, but
        // keep Applet requests and per-agent credentials separate from MCP.
        _ = try MCPBridgeFiles.prepare(workspace: workspace)
        let directory = workspace.appendingPathComponent(".noodle/applet-bridge")
        if (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]
            as? FileAttributeType) == .typeSymbolicLink
        {
            throw AppletError("Unsafe Applet bridge directory.")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
}
