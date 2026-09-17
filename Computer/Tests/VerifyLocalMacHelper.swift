import Foundation

let path = CommandLine.arguments[1], entitlements = CommandLine.arguments[2]
let data = try Data(contentsOf: URL(fileURLWithPath: entitlements))
if !data.isEmpty {
    let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    precondition(values.isEmpty, "Local Mac helpers must not carry optional entitlements: \(path)")
}
print("Local Mac helper has no optional entitlements: \((path as NSString).lastPathComponent)")
if path.hasSuffix(".app") {
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    precondition(info["LSUIElement"] as? Bool == true, "Local Mac helper apps must stay out of the Dock: \(path)")
}
if path.hasSuffix("/LocalMacDesktop.app") {
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    for key in ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription"] {
        precondition((info[key] as? String)?.isEmpty == false, "Missing account folder access description: \(key)")
    }
}
