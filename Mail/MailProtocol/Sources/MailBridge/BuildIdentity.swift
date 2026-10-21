import Foundation
import Security

/// Exact production/development identities for Noodle Mail, the Noodle broker and its Mail tool extension.
public enum MailBuildIdentity: String, CaseIterable, Sendable {
    case production, development

    public var providerID: String { "com.pdparchitect.noodle.mail" + suffix }
    public var noodleID: String { "com.pdparchitect.noodle" + suffix }
    /// Noodle's bundled Mail tool extension. It forwards calls the Noodle broker has
    /// already authorized; assignment decisions never move into it.
    public var toolExtensionID: String { noodleID + ".tools.mail" }
    /// No Hub: bots kept on a Noodle Hub don't get mailboxes yet.
    public var clientIDs: [String] { [noodleID, toolExtensionID] }
    public var groupSuffix: String { "com.pdparchitect.noodle.mails" + suffix }
    public var appName: String { "Noodle Mail" + (self == .development ? " Dev" : "") }
    public var urlScheme: String { self == .development ? "noodlemail-dev" : "noodlemail" }
    private var suffix: String { self == .development ? ".local" : "" }

    public static func identify(_ identifier: String?) -> Self? {
        allCases.first { [$0.providerID, $0.noodleID, $0.toolExtensionID].contains(identifier ?? "") }
    }
    public static let processIdentity: Self? = {
        // Paths and request fields cannot select another environment.
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
    // the connection require a known signed identity.
    public static var current: Self { processIdentity ?? .production }
    public func validateGroup(_ group: String, team: String) throws {
        guard group == team + "." + groupSuffix else {
            throw MailError("The Mail connection group does not match this build.")
        }
    }
}
