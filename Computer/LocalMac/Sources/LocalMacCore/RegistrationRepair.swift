import Foundation

/// The setup app alone supplies SMAppService operations for its fixed daemon.
/// Only an explicit repair action may unregister; startup/status never do so.
@MainActor public final class LocalMacRegistrationRepair {
    public private(set) var inProgress = false
    public init() {}

    public func repair(status: () -> LocalMacRegistrationStatus,
                       verify: () throws -> Void,
                       unregister: () async throws -> Void,
                       register: () throws -> Void,
                       pause: () async -> Void = {
                           await withCheckedContinuation { continuation in
                               DispatchQueue.main.asyncAfter(deadline: .now() + 1) { continuation.resume() }
                           }
                       }) async throws -> LocalMacRegistrationStatus {
        guard !inProgress else { throw LocalMacError("Local Mac repair is already in progress.") }
        inProgress = true
        defer { inProgress = false }
        let initial = status()
        // A denied/awaiting approval service needs the native approval flow,
        // not an unregister/register loop that overrides the user's choice.
        if initial == .requiresApproval { return initial }
        guard initial == .enabled || initial == .notRegistered else {
            throw LocalMacError("The installed Local Mac helper could not be verified. Reinstall this Computer app before repairing it.")
        }
        try verify()
        try Task.checkCancellation()
        if initial == .enabled { try await unregister() }
        // Finish registration even if cancellation arrives after unregister.
        // Apple's completion-handler API confirms the old process was reaped.
        for attempt in 0..<6 {
            do { try register(); return status() }
            catch {
                let current = status()
                if current == .requiresApproval { return current }
                let failure = error as NSError
                // macOS can report a stale disabled disposition immediately
                // after its unregister completion handler. Retry only this
                // observed transition, never signature/authorization failures
                // or a user-disabled service, and never unregister a second time.
                guard initial == .enabled, current == .notRegistered,
                      failure.domain == "SMAppServiceErrorDomain", failure.code == 1,
                      attempt < 5 else { throw error }
                await pause()
                try verify()
                if status() == .requiresApproval { return .requiresApproval }
            }
        }
        throw LocalMacError("Local Mac registration did not finish. Retry Repair Local Mac.")
    }
}
