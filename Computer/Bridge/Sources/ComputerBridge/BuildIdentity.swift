import Foundation

/// Each signed app pair owns one connection group. Never discover or authenticate
/// a provider from the other channel, even when both are installed or running.
public enum ComputerBuildIdentity: String, CaseIterable, Sendable {
    case production, development, testing

    public var providerID: String {
        switch self {
        case .production: "com.pdparchitect.noodle.computer"
        case .development: "com.pdparchitect.noodle.computer.local"
        case .testing: "com.pdparchitect.noodle.computer.tests"
        }
    }
    /// Noodle, then its bundled Computer tool extension. The extension forwards calls the
    /// Noodle broker already authorized; assignment decisions never move into it.
    public var clientIDs: [String] {
        let noodle = switch self {
        case .production: "com.pdparchitect.noodle"
        case .development: "com.pdparchitect.noodle.local"
        case .testing: "com.pdparchitect.noodle.integration"
        }
        return [noodle, noodle + ".tools.computer"]
    }
    /// Every Noodle client of one channel is the same owner of a bot's terminals, so
    /// Noodle can revoke what its tool extension opened.
    public static func principal(for clientID: String) -> String {
        allCases.first { $0.clientIDs.contains(clientID) }?.clientIDs[0] ?? clientID
    }
    public var appName: String {
        switch self {
        case .production: "Noodle Computer"
        case .development: "Noodle Computer Dev"
        case .testing: "Noodle Computer Tests"
        }
    }
    public var groupSuffix: String {
        "com.pdparchitect.noodle.computers" + (self == .production ? "" : self == .development ? ".local" : ".tests")
    }
    public var fileExtension: String {
        "noodlecomputer" + (self == .production ? "" : self == .development ? "-dev" : "-tests")
    }
    public var urlScheme: String { fileExtension }
    public var contentType: String {
        "com.pdparchitect.noodle.computer-reference" + (self == .production ? "" : self == .development ? "-dev" : "-tests")
    }
    /// Storage identity predates the visible Dev label. Never derive persisted
    /// account records from a display name or relocate them during an app rename.
    public var storageName: String {
        self == .development ? "Noodle Computer Local" : appName
    }
    public static func identify(_ bundleIdentifier: String?) -> Self? {
        allCases.first {
            [$0.providerID, $0.providerID + ".preview", $0.providerID + ".thumbnail"].contains(bundleIdentifier ?? "")
                || $0.clientIDs.contains(bundleIdentifier ?? "")
        }
    }
    public static var current: Self { identify(Bundle.main.bundleIdentifier) ?? .production }
}
