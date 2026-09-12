import Foundation

func plist(_ path: String) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
}
let info = try plist(CommandLine.arguments[1]), entitlements = try plist(CommandLine.arguments[2])
let version = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let required: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.network.client", "com.apple.security.files.user-selected.read-write",
    "com.apple.security.application-groups", "com.apple.security.temporary-exception.mach-lookup.global-name"]
precondition(Set(entitlements.keys) == required, "Unexpected Applet entitlement set")
for key in required where !key.contains("application-groups") && !key.contains("mach-lookup") {
    precondition(entitlements[key] as? Bool == true, "Missing grant: \(key)")
}
let team = info["NoodleSigningTeam"] as! String, bundle = info["CFBundleIdentifier"] as! String
precondition(entitlements["com.apple.security.application-groups"] as? [String] == ["\(team).com.pdparchitect.noodle.applets"])
precondition(entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String] == ["\(bundle)-spks", "\(bundle)-spki"])
precondition(info["CFBundleShortVersionString"] as? String == version && info["CFBundleVersion"] as? String == version)
precondition(info["LSMinimumSystemVersion"] as? String == "15.0")
precondition((info["CFBundleURLTypes"] as? [[String: Any]])?.contains {
    $0["CFBundleURLSchemes"] as? [String] == ["noodlet"]
} == true, "Missing noodlet URL handler")
precondition(info["SUAllowsAutomaticUpdates"] as? Bool == true)
precondition(info["SUAutomaticallyUpdate"] as? Bool == false)
print("Applet version, six-key sandbox policy and opt-in automatic-install update policy verified")
let previewInfo = try plist(CommandLine.arguments[4]), previewEntitlements = try plist(CommandLine.arguments[5])
precondition(previewInfo["CFBundleIdentifier"] as? String == "com.pdparchitect.noodle.applet.preview")
precondition(previewInfo["CFBundleVersion"] as? String == version)
let definition = previewInfo["NSExtension"] as! [String: Any]
precondition(definition["NSExtensionPointIdentifier"] as? String == "com.apple.quicklook.preview")
precondition((definition["NSExtensionAttributes"] as! [String: Any])["QLSupportedContentTypes"] as? [String] == ["com.pdparchitect.noodle.noodlet"])
precondition(Set(previewEntitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.application-groups"])
precondition(previewEntitlements["com.apple.security.app-sandbox"] as? Bool == true)
precondition(previewEntitlements["com.apple.security.network.client"] as? Bool == true)
precondition(previewEntitlements["com.apple.security.application-groups"] as? [String] == ["\(team).com.pdparchitect.noodle.applets"])
print("Quick Look extension type registration, version and three-key sandbox policy verified")
