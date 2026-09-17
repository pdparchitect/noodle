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
let bundle = app["CFBundleIdentifier"] as! String
let suffix = bundle.hasSuffix(".local") ? "-dev" : bundle.hasSuffix(".tests") ? "-tests" : ""
let contentType = "com.pdparchitect.noodle.computer-reference" + suffix
precondition(attributes["QLSupportedContentTypes"] as? [String] == [contentType])
let types = app["CFBundleDocumentTypes"] as! [[String: Any]]
precondition(types.count == 1 && types.first?["LSItemContentTypes"] as? [String] == [contentType])
let exports = app["UTExportedTypeDeclarations"] as! [[String: Any]]
precondition(exports.count == 1 && exports[0]["UTTypeIdentifier"] as? String == contentType)
let tags = exports[0]["UTTypeTagSpecification"] as! [String: Any]
precondition(tags["public.filename-extension"] as? [String] == ["noodlecomputer" + suffix])
precondition(tags["public.mime-type"] as? [String] == ["application/vnd.noodle.computer" + suffix + "+json"])
print("Computer \(kind) extension: identity, document-type declarations and sandbox-only entitlement verified")
