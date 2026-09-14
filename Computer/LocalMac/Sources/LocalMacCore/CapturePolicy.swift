import Foundation

/// Capture approval is independent of desktop resolution. The client supplies
/// its main-session display IDs; the account helper must reject every one.
public enum LocalMacCapturePolicy {
    public static func validateProtectedDisplays(_ ids: [UInt32]) throws {
        guard !ids.isEmpty, ids.count <= 32, !ids.contains(0), Set(ids).count == ids.count else {
            throw LocalMacError("Cannot verify the main desktop's displays before capture.")
        }
    }
    public static func validate(displayID: UInt32, isBuiltin: Bool, protectedIDs: [UInt32]) throws {
        try validateProtectedDisplays(protectedIDs)
        guard displayID != 0, !isBuiltin, !protectedIDs.contains(displayID) else {
            throw LocalMacError("Refused to capture a display belonging to the main desktop.")
        }
    }
}
