import ComputerBridge
import Foundation

/// Fixed namespaces only: no caller-supplied service, credential or storage path.
public struct LocalMacIdentity: Equatable, Sendable {
    public let build: ComputerBuildIdentity
    public init?(providerID: String?) {
        guard let build = ComputerBuildIdentity.allCases.first(where: { $0.providerID == providerID }) else { return nil }
        self.build = build
    }
    public static func setup(_ identifier: String?) -> Self? {
        ComputerBuildIdentity.allCases.compactMap { Self(providerID: $0.providerID) }.first { $0.setupID == identifier }
    }
    public static func desktop(_ identifier: String?) -> Self? {
        ComputerBuildIdentity.allCases.compactMap { Self(providerID: $0.providerID) }.first { $0.desktopID == identifier }
    }
    public var providerID: String { build.providerID }
    public var serviceID: String { providerID + ".localmac" }
    public var setupID: String { providerID + ".localmacsetup" }
    public var setupAppName: String { build.appName + " Setup" }
    public var desktopID: String { providerID + ".desktop" }
    public var daemonPlist: String { serviceID + ".plist" }
    public var permitsAccountService: Bool { build != .testing }
    public var storageDirectory: URL {
        URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
            .appendingPathComponent(build.storageName, isDirectory: true).appendingPathComponent("Local Mac", isDirectory: true)
    }
    public var desktopAppName: String { build == .development ? "Noodle Local Mac Desktop Dev" : "Noodle Local Mac Desktop" }
    public func group(team: String) -> String { team + "." + build.groupSuffix }
}
