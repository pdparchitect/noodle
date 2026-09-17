import Foundation
import AppKit
import LocalMacCore
import ServiceManagement

enum LocalMacErrorRecovery: Equatable {
    case fullDiskAccess, loginItems, setup, repair
    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access Required"
        case .loginItems, .setup, .repair: "Local Mac Helper Unavailable"
        }
    }
    var actionTitle: String {
        switch self {
        case .fullDiskAccess: "Open Full Disk Access…"
        case .loginItems: "Open Login Items…"
        case .setup: "Open Local Mac Setup…"
        case .repair: "Repair Local Mac…"
        }
    }
    @MainActor func open() throws {
        switch self {
        case .fullDiskAccess: NSWorkspace.shared.open(LocalMacRemovalFailure.privacySettingsURL)
        case .loginItems: SMAppService.openSystemSettingsLoginItems()
        case .setup, .repair: try LocalMacSetup.enable()
        }
    }
}

extension LocalMacRegistrationStatus {
    var setupTitle: String {
        switch self {
        case .notRegistered: "Enable Local Mac"
        case .requiresApproval: "Approval required"
        case .enabled: "Local Mac enabled"
        case .helperMissing: "Local Mac helper missing"
        case .unknown: "Setup status unavailable"
        }
    }
    var setupActionTitle: String {
        switch self {
        case .requiresApproval: "Open System Settings…"
        case .notRegistered: "Enable Local Mac…"
        default: "Open Local Mac Setup…"
        }
    }
}

extension ComputerSession {
    /// Refresh only the setup state. Returning from approval never creates or
    /// starts an account automatically, and cannot overwrite an in-flight start.
    func refreshLocalMacSetup(read: () async -> LocalMacRegistrationStatus = { await LocalMacSetup.registrationStatus() }) async {
        guard computer.kind == .localMac, phase.canStart else { return }
        let previous = phase
        let status = await read()
        guard !Task.isCancelled, phase == previous else { return }
        switch status {
        case .notRegistered, .requiresApproval: phase = .setupRequired(status)
        case .enabled:
            if case .setupRequired = phase { phase = .stopped }
        case .helperMissing: recordStartupFailure(LocalMacSetupRequired(registration: status))
        case .unknown: break // Preserve the last known state; no evidence approval changed.
        }
    }
}
