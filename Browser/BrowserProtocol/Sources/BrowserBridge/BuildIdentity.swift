import Foundation
import Security

/// Exact production/development identities for the companion, the Noodle broker and its Browser tool extension.
public enum BrowserBuildIdentity: String, CaseIterable, Sendable {
    case production, development

    public var providerID: String { "com.pdparchitect.noodle.browser" + suffix }
    public var noodleID: String { "com.pdparchitect.noodle" + suffix }
    /// Noodle's bundled Browser tool extension. It forwards calls the Noodle broker has
    /// already authorized; assignment decisions never move into it.
    public var toolExtensionID: String { noodleID + ".tools.browser" }
    /// Noodle Hub, which runs the browsers of the bots people keep on it.
    public var hubID: String { "com.pdparchitect.noodle.hub" + suffix }
    public var clientIDs: [String] { [noodleID, toolExtensionID, hubID] }
    public var groupSuffix: String { "com.pdparchitect.noodle.browsers" + suffix }
    public var appName: String { "Noodle Browser" + (self == .development ? " Dev" : "") }
    public var urlScheme: String { self == .development ? "noodlebrowser-dev" : "noodlebrowser" }
    private var suffix: String { self == .development ? ".local" : "" }

    public static func identify(_ identifier: String?) -> Self? {
        allCases.first { [$0.providerID, $0.noodleID, $0.toolExtensionID, $0.hubID].contains(identifier ?? "") }
    }
    public static let processIdentity: Self? = {
        // Paths and request flags cannot select another environment.
        var code: SecCode?
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
           let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String,
           let value = identify(identifier) { return value }
        return identify(Bundle.main.bundleIdentifier)
    }()
    // Unsigned unit tests retain production defaults. Discovery, launch and
    // the provider connection require a known signed/bundled identity.
    public static var current: Self { processIdentity ?? .production }
    public func validateGroup(_ group: String, team: String) throws {
        guard group == team + "." + groupSuffix else {
            throw BrowserError("The Browser connection group does not match this build.")
        }
    }
}
