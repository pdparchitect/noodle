import BrowserBridge
import Foundation
@_exported import NoodleExternalTools

/// Where Noodle Browser and its command-line tool meet: an app group of their own, so nothing in
/// Noodle's or Noodle Hub's sandbox can reach it. Both read it from the app's Info.plist; the
/// tool sits in the app's Contents/MacOS, so the app's bundle is its main bundle too.
public enum BrowserExternal {
    public static func root(bundle: Bundle = .main) throws -> URL {
        let build = BrowserBuildIdentity.current
        guard let group = bundle.object(forInfoDictionaryKey: "NoodleBrowserExternalGroup") as? String,
              group == (try BrowserConnection.signingTeam(bundle: bundle)) + "." + build.externalGroupSuffix else {
            throw BrowserError("External tools are not configured in this build of \(build.appName).")
        }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw BrowserError("The external tools folder is unavailable.")
        }
        return root
    }
    public static func socketURL(bundle: Bundle = .main) throws -> URL { try root(bundle: bundle).appendingPathComponent("x.sock") }
    /// The person's answers about which apps may use what.
    public static func grantsURL(library: URL) -> URL { library.appendingPathComponent("external-tools.json") }
}
