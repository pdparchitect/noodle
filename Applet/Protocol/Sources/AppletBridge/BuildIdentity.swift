import Foundation
import Security

/// Fixed production/development namespaces, shared by the app, Noodle, Noodle Hub and the preview extension.
public enum AppletBuildIdentity: String, CaseIterable, Sendable {
    case production, development

    public var providerID: String { "com.pdparchitect.noodle.applet" + suffix }
    public var noodleID: String { "com.pdparchitect.noodle" + suffix }
    public var previewID: String { providerID + ".preview" }
    /// Noodle Hub, which runs the noodlets of the bots people keep on it. Like Noodle, it passes
    /// a bot's request on for that bot, and acts for its own person when it names no bot.
    public var hubID: String { "com.pdparchitect.noodle.hub" + suffix }
    public var clientIDs: [String] { [noodleID, hubID] }
    public var groupSuffix: String { "com.pdparchitect.noodle.applets" + suffix }
    public var appName: String { "Noodle Applet" + (self == .development ? " Dev" : "") }
    public var fileExtension: String { self == .development ? "noodlet-dev" : "noodlet" }
    public var urlScheme: String { fileExtension }
    public var contentType: String { "com.pdparchitect.noodle." + fileExtension }
    private var suffix: String { self == .development ? ".local" : "" }

    public static func identify(_ identifier: String?) -> Self? {
        allCases.first { [$0.providerID, $0.noodleID, $0.previewID, $0.hubID].contains(identifier ?? "") }
    }
    public static func document(_ url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        // Existing development packages remain readable; all new documents use Dev.
        if url.pathExtension == "noodlet-local" { return .development }
        return allCases.first { $0.fileExtension == url.pathExtension }
    }
    public static let processIdentity: Self? = {
        // The code-signing identifier retains the channel; paths and flags cannot select it.
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
    // Pure format utilities and unsigned unit tests retain production defaults.
    // Discovery and launch require a known signed/bundled identity.
    public static var current: Self { processIdentity ?? .production }
    public func validateGroup(_ group: String, team: String) throws {
        guard group == team + "." + groupSuffix else {
            throw AppletError("The Applet connection group does not match this build.")
        }
    }
}
