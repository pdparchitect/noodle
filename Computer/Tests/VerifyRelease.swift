import Foundation

func plist(_ path: String) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
}
let info = try plist(CommandLine.arguments[1]), entitlements = try plist(CommandLine.arguments[2])
let version = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let required: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.virtualization",
    "com.apple.security.network.client", "com.apple.security.files.user-selected.read-write",
    "com.apple.security.application-groups", "com.apple.security.temporary-exception.mach-lookup.global-name",
    "com.apple.security.temporary-exception.files.home-relative-path.read-only"]
precondition(Set(entitlements.keys) == required, "Unexpected Computer entitlement set")
for key in required where !key.contains("application-groups") && !key.contains("temporary-exception") {
    precondition(entitlements[key] as? Bool == true, "Missing grant: \(key)")
}
// Read-only, and only the folder holding system wallpapers the user has downloaded.
precondition(entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String] == ["/Library/Application Support/com.apple.mobileAssetDesktop/", "/Library/Application Support/com.apple.wallpaper/aerials/"],
    "Unexpected home-relative read-only exception")
let team = info["NoodleSigningTeam"] as! String, bundle = info["CFBundleIdentifier"] as! String
let suffix: String
switch bundle {
case "com.pdparchitect.noodle.computer": suffix = ""
case "com.pdparchitect.noodle.computer.local": suffix = ".local"
case "com.pdparchitect.noodle.computer.tests": suffix = ".tests"
default: fatalError("Unknown Computer identity")
}
let group = "\(team).com.pdparchitect.noodle.computers" + suffix
precondition(info["NoodleComputerGroup"] as? String == group)
precondition(entitlements["com.apple.security.application-groups"] as? [String] == [group])
if suffix == ".local" { precondition(info["NoodleUpdatesEnabled"] as? Bool == false) }
let contents = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
let setup = contents.appendingPathComponent("Helpers/LocalMacSetup.app/Contents")
let setupInfo = try plist(setup.appendingPathComponent("Info.plist").path)
let setupURL = setup.deletingLastPathComponent()
let setupName = (info["CFBundleDisplayName"] as! String) + " Setup"
precondition(setupInfo["CFBundleName"] as? String == "LocalMacSetup")
precondition(setupInfo["CFBundleDisplayName"] as? String == "LocalMacSetup")
precondition(setupInfo["CFBundleDevelopmentRegion"] as? String == "en")
let setupBundle = Bundle(url: setupURL)!
precondition(setupBundle.object(forInfoDictionaryKey: "CFBundleName") as? String == setupName)
precondition(setupBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == setupName)
precondition(FileManager.default.displayName(atPath: setupURL.path) == setupName,
             "macOS must resolve the setup helper's build-specific display name")
print("Local Mac setup display name verified: " + setupName)
let desktopInfo = try plist(contents.appendingPathComponent("Helpers/LocalMacDesktop.app/Contents/Info.plist").path)
let desktopURL = contents.appendingPathComponent("Helpers/LocalMacDesktop.app")
let desktopName = "Noodle Local Mac Desktop" + (suffix == ".local" ? " Dev" : "")
precondition(Bundle(url: desktopURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == desktopName)
precondition(FileManager.default.displayName(atPath: desktopURL.path) == desktopName,
             "macOS must resolve the desktop helper's build-specific display name")
precondition(setupInfo["CFBundleIdentifier"] as? String == bundle + ".localmacsetup")
precondition(desktopInfo["CFBundleIdentifier"] as? String == bundle + ".desktop")
let daemon = try plist(setup.appendingPathComponent("Library/LaunchDaemons/" + bundle + ".localmac.plist").path)
precondition(daemon["Label"] as? String == group + ".localmac")
precondition(daemon["MachServices"] as? [String: Bool] == [group + ".localmac": true])
precondition(daemon["AssociatedBundleIdentifiers"] as? [String] == [bundle])
precondition(daemon["BundleProgram"] as? String == "Contents/Library/LaunchServices/LocalMacService")
precondition(entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String] == ["\(bundle)-spks", "\(bundle)-spki"])
precondition(info["CFBundleShortVersionString"] as? String == version && info["CFBundleVersion"] as? String == version)
precondition(info["LSMinimumSystemVersion"] as? String == "26.0")
precondition((info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty == false)
precondition(info["SUAllowsAutomaticUpdates"] as? Bool == true)
precondition(info["SUAutomaticallyUpdate"] as? Bool == false)
print("Computer version, six-key sandbox policy and opt-in automatic-install update policy verified")
