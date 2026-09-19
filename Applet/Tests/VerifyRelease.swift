import Foundation

func plist(_ path: String) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
}
let info = try plist(CommandLine.arguments[1]), entitlements = try plist(CommandLine.arguments[2])
let version = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let required: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.network.client", "com.apple.security.device.audio-input",
    "com.apple.security.device.camera",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.application-groups", "com.apple.security.temporary-exception.mach-lookup.global-name",
    "com.apple.security.temporary-exception.files.home-relative-path.read-only"]
precondition(Set(entitlements.keys) == required, "Unexpected Applet entitlement set")
for key in required where !key.contains("application-groups") && !key.contains("temporary-exception") {
    precondition(entitlements[key] as? Bool == true, "Missing grant: \(key)")
}
// Read-only, and only the folder holding system wallpapers the user has downloaded.
precondition(entitlements["com.apple.security.temporary-exception.files.home-relative-path.read-only"] as? [String] == ["/Library/Application Support/com.apple.mobileAssetDesktop/", "/Library/Application Support/com.apple.wallpaper/aerials/"],
    "Unexpected home-relative read-only exception")
let team = info["NoodleSigningTeam"] as! String, bundle = info["CFBundleIdentifier"] as! String
let local = bundle == "com.pdparchitect.noodle.applet.local"
precondition(local || bundle == "com.pdparchitect.noodle.applet")
let group = "\(team).com.pdparchitect.noodle.applets" + (local ? ".local" : "")
let documentExtension = local ? "noodlet-dev" : "noodlet"
let contentType = "com.pdparchitect.noodle." + documentExtension
precondition(info["NoodleAppletGroup"] as? String == group)
precondition(entitlements["com.apple.security.application-groups"] as? [String] == [group])
if local { precondition(info["NoodleUpdatesEnabled"] as? Bool == false) }
precondition(entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String] == ["\(bundle)-spks", "\(bundle)-spki"])
precondition(info["CFBundleShortVersionString"] as? String == version && info["CFBundleVersion"] as? String == version)
precondition(info["LSMinimumSystemVersion"] as? String == "15.0")
// Noodlets that declare these permissions prompt as Applet.
for key in ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSSpeechRecognitionUsageDescription"] {
    precondition(info[key] is String, "Missing usage description: \(key)")
}
let links = info["CFBundleURLTypes"] as! [[String: Any]]
precondition(links.count == 1 && links[0]["CFBundleURLSchemes"] as? [String] == [documentExtension], "Cross-environment URL registration")
let types = info["CFBundleDocumentTypes"] as! [[String: Any]]
precondition(types.count == 1 && types[0]["LSItemContentTypes"] as? [String] == [contentType], "Cross-environment file registration")
let exports = info["UTExportedTypeDeclarations"] as! [[String: Any]]
precondition(exports.count == 1 && exports[0]["UTTypeIdentifier"] as? String == contentType)
precondition((exports[0]["UTTypeTagSpecification"] as! [String: Any])["public.filename-extension"] as? [String] == [documentExtension])
precondition(info["UTImportedTypeDeclarations"] == nil)
precondition(info["SUAllowsAutomaticUpdates"] as? Bool == true)
precondition(info["SUAutomaticallyUpdate"] as? Bool == false)
print("Applet version, nine-key sandbox policy and opt-in automatic-install update policy verified")
let previewInfo = try plist(CommandLine.arguments[4]), previewEntitlements = try plist(CommandLine.arguments[5])
precondition(previewInfo["CFBundleIdentifier"] as? String == bundle + ".preview")
precondition(previewInfo["CFBundleVersion"] as? String == version)
let definition = previewInfo["NSExtension"] as! [String: Any]
precondition(definition["NSExtensionPointIdentifier"] as? String == "com.apple.quicklook.preview")
precondition((definition["NSExtensionAttributes"] as! [String: Any])["QLSupportedContentTypes"] as? [String] == [contentType])
precondition(Set(previewEntitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.application-groups"])
precondition(previewEntitlements["com.apple.security.app-sandbox"] as? Bool == true)
precondition(previewEntitlements["com.apple.security.network.client"] as? Bool == true)
precondition(previewEntitlements["com.apple.security.application-groups"] as? [String] == [group])
print("Quick Look extension type registration, version and three-key sandbox policy verified")

precondition(previewInfo["NoodleAppletGroup"] as? String == group)
