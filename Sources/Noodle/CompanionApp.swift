import AppKit
import ComputerBridge
import AppletBridge
import BrowserBridge

/// Separately installed apps that extend Noodle. Bundled helpers and harnesses
/// are managed elsewhere and are not companion apps.
enum CompanionApp: String, CaseIterable, Identifiable {
    case computer, applet, browser

    var id: String { rawValue }

    var name: String {
        switch self {
        case .computer: ComputerBuildIdentity.current.appName
        case .applet: AppletBuildIdentity.current.appName
        case .browser: BrowserBuildIdentity.current.appName
        }
    }

    var summary: String {
        switch self {
        case .browser: "Give your bots persistent browsers for websites, signed-in accounts, and file transfers."
        case .computer: "Give your bots Linux desktops and terminals to run tools and work on files."
        case .applet: "Create and enjoy little tools, websites, games, and native experiments."
        }
    }

    var requirements: String {
        switch self {
        case .browser: "Requires macOS 26 or later."
        case .computer: "Requires Apple silicon and macOS 26 or later."
        case .applet: "Requires macOS 15 or later. Swift noodlets also require Apple's developer tools."
        }
    }

    var systemImage: String {
        switch self {
        case .browser: "globe"
        case .computer: "desktopcomputer"
        case .applet: "square.grid.2x2"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .browser: BrowserConnection.providerID
        case .computer: ComputerConnection.providerID
        case .applet: AppletConnection.providerID
        }
    }

    var documentationURL: URL {
        switch self {
        case .browser: URL(string: "https://github.com/pdparchitect/noodle/tree/main/Browser")!
        case .computer: ComputerDistribution.documentation
        case .applet: URL(string: "https://github.com/pdparchitect/noodle/tree/main/Applet")!
        }
    }

    @MainActor static func installedApps() -> [Self: CompanionAppInstallation] {
        var result: [Self: CompanionAppInstallation] = [:]
        for app in allCases {
            let url: URL?
            switch app {
            case .computer: url = ComputerApplication.locate()
            case .applet: url = AppletApplication.locate()
            case .browser: url = BrowserApplication.locate()
            }
            if let url {
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
