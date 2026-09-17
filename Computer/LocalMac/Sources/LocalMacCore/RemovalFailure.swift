import Darwin
import Foundation

/// A deletion-specific reply, separate from the human-readable fallback used by
/// older clients. Recovery is based on the failed operation, not message parsing.
public struct LocalMacRemovalFailure: Codable, LocalizedError, Equatable, Sendable {
    public let code: Int
    public let path: String
    public let operation: String
    public let preflight: Bool

    public init(_ error: NSError) {
        code = error.code
        path = error.userInfo["LocalMacRemovalPath"] as? String ?? ""
        operation = error.userInfo["LocalMacRemovalOperation"] as? String ?? "unknown"
        preflight = error.userInfo["LocalMacRemovalPreflight"] as? Bool ?? false
    }

    public var offersPrivacySettings: Bool {
        // EPERM during folder enumeration is how macOS reports a TCC denial.
        // Ownership changes, locked files and ordinary UNIX EACCES are distinct.
        code == EPERM && ["open", "read"].contains(operation)
    }
    public static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    public func message(appName: String) -> String {
        let location = path.isEmpty ? "the home folder" : "“\(path)”"
        let detail: String
        if offersPrivacySettings {
            detail = "macOS blocked access to \(location). To delete this Local Mac’s home, allow \(appName) in System Settings → Privacy & Security → Full Disk Access, then reopen the app and retry Delete."
        } else if operation == "identity" || operation == "boundary" {
            detail = "The managed home’s identity or location changed. Deletion was refused."
        } else if operation == "locked" {
            detail = "Cannot delete \(location) because it is locked. Unlock it before retrying Delete."
        } else {
            detail = "Cannot delete \(location): \(String(cString: strerror(Int32(clamping: code))))."
        }
        return detail + (preflight
            ? " No files were removed by this attempt. The account was retained."
            : " Deletion stopped; some files may already have been removed. The account was retained.")
    }
    public var errorDescription: String? { message(appName: "Noodle Computer") }
}
