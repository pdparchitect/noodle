import Foundation

let path = CommandLine.arguments[1], entitlements = CommandLine.arguments[2]
let data = try Data(contentsOf: URL(fileURLWithPath: entitlements))
var values: [String: Any] = [:]
if !data.isEmpty {
    guard let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        fatalError("Invalid helper entitlements: \(path)")
    }
    values = decoded
}
if path.hasSuffix("/LocalMacDesktop.app") {
    precondition(values.count == 1 && values["com.apple.security.automation.apple-events"] as? Bool == true,
                 "The desktop helper must carry only the Apple Events consent entitlement: \(path)")
    print("Local Mac desktop helper has only the Apple Events consent entitlement")
} else {
    precondition(values.isEmpty, "Local Mac helpers must not carry optional entitlements: \(path)")
    print("Local Mac helper has no optional entitlements: \((path as NSString).lastPathComponent)")
}
if path.hasSuffix(".app") {
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    precondition(info["LSUIElement"] as? Bool == true, "Local Mac helper apps must stay out of the Dock: \(path)")
}
if path.hasSuffix("/LocalMacDesktop.app") {
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    for key in ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription", "NSAppleEventsUsageDescription"] {
        precondition((info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                     "Missing account access description: \(key)")
    }
}
