import Foundation

func plist(_ path: String) throws -> [String: Any] {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
}
let info = try plist(CommandLine.arguments[1]), entitlements = try plist(CommandLine.arguments[2])
let app = try plist(CommandLine.arguments[3]), kind = CommandLine.arguments[4].lowercased()
precondition(Set(entitlements.keys) == ["com.apple.security.app-sandbox"])
precondition(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
precondition(info["CFBundleIdentifier"] as? String == (app["CFBundleIdentifier"] as! String) + "." + kind)
precondition(info["CFBundleVersion"] as? String == app["CFBundleVersion"] as? String)
let ext = info["NSExtension"] as! [String: Any]
precondition(ext["NSExtensionPointIdentifier"] as? String == "com.apple.quicklook." + kind)
let attributes = ext["NSExtensionAttributes"] as! [String: Any]
precondition(attributes["QLSupportedContentTypes"] as? [String] == ["com.pdparchitect.noodle.computer-reference"])
let types = app["CFBundleDocumentTypes"] as! [[String: Any]]
precondition(types.first?["LSItemContentTypes"] as? [String] == ["com.pdparchitect.noodle.computer-reference"])
print("Computer \(kind) extension: identity, document-type declarations and sandbox-only entitlement verified")
