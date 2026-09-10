import Foundation

func plist(_ path: String) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
}
let info = try plist(CommandLine.arguments[1]), entitlements = try plist(CommandLine.arguments[2])
let version = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let required: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.virtualization",
    "com.apple.security.network.client", "com.apple.security.files.user-selected.read-only",
    "com.apple.security.application-groups", "com.apple.security.temporary-exception.mach-lookup.global-name"]
precondition(Set(entitlements.keys) == required, "Unexpected Computer entitlement set")
for key in required where !key.contains("application-groups") && !key.contains("mach-lookup") {
    precondition(entitlements[key] as? Bool == true, "Missing grant: \(key)")
}
let team = info["NoodleSigningTeam"] as! String, bundle = info["CFBundleIdentifier"] as! String
precondition(entitlements["com.apple.security.application-groups"] as? [String] == ["\(team).com.pdparchitect.noodle.computers"])
precondition(entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String] == ["\(bundle)-spks", "\(bundle)-spki"])
precondition(info["CFBundleShortVersionString"] as? String == version && info["CFBundleVersion"] as? String == version)
precondition(info["LSMinimumSystemVersion"] as? String == "26.0")
precondition(info["SUAllowsAutomaticUpdates"] as? Bool == false)
precondition(info["SUAutomaticallyUpdate"] as? Bool == false)
print("Computer version, six-key sandbox policy and manual-install update policy verified")
