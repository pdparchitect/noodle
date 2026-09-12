import AppKit
import ComputerBridge
import AppletBridge

/// Separately installed apps that extend Noodle. Bundled helpers and harnesses
/// are managed elsewhere and are not companion apps.
enum CompanionApp: String, CaseIterable, Identifiable {
    case computer, applet

    var id: String { rawValue }

    var name: String {
        switch self {
        case .computer: "Noodle Computer"
        case .applet: "Noodle Applet"
        }
    }

    var summary: String {
        switch self {
        case .computer: "Give your bots Linux desktops and terminals to run tools and work on files."
        case .applet: "Create and enjoy little tools, websites, games, and native experiments."
        }
    }

    var requirements: String {
        switch self {
        case .computer: "Requires Apple silicon and macOS 26 or later."
        case .applet: "Requires macOS 15 or later. Swift noodlets also require Apple's developer tools."
        }
    }

    var systemImage: String {
        switch self {
        case .computer: "desktopcomputer"
        case .applet: "square.grid.2x2"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .computer: ComputerConnection.providerID
        case .applet: AppletConnection.providerID
        }
    }

    var documentationURL: URL {
        switch self {
        case .computer: ComputerDistribution.documentation
        case .applet: URL(string: "https://github.com/pdparchitect/noodle/tree/main/Applet")!
        }
    }

    @MainActor static func installedApps() -> [Self: CompanionAppInstallation] {
        var result: [Self: CompanionAppInstallation] = [:]
        for app in allCases {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                result[app] = CompanionAppInstallation(applicationURL: url)
            }
        }
        return result
    }
}

struct CompanionAppInstallation: Equatable {
    let applicationURL: URL
    let version: String?

    init?(applicationURL: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        self.applicationURL = applicationURL
        // Read afresh because Bundle caches metadata across an app replacement.
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: infoURL)).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
        }
        let value = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        version = value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
