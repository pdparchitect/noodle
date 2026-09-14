import Foundation
import Security

public enum LocalMacSignedCode {
    public static func fingerprint(at url: URL, requirement text: String) throws -> Data {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw LocalMacError("The installed Local Mac service failed signature verification. Reinstall the signed Noodle Computer app; accounts are retained.")
        }
        return try fingerprint(code)
    }

    /// Query the loaded image, not the path which an app update may have replaced.
    public static func runningFingerprint() throws -> Data {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw LocalMacError("Cannot identify the running Local Mac service.")
        }
        return try fingerprint(staticCode)
    }

    private static func fingerprint(_ code: SecStaticCode) throws -> Data {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let value = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !value.isEmpty else {
            throw LocalMacError("Cannot verify the Local Mac service version.")
        }
        return value
    }
}

public struct LocalMacServiceInfo: Codable, Sendable {
    public static let version = 1
    public var protocolVersion: Int
    public var fingerprint: Data
    public var restarting: Bool
    public init(fingerprint: Data, restarting: Bool = false) {
        protocolVersion = Self.version; self.fingerprint = fingerprint; self.restarting = restarting
    }
    /// False means a verified replacement is restarting; no lifecycle mutation
    /// should be sent until the next connection reports the expected image.
    public func isReady(expected: Data) throws -> Bool {
        if restarting { return false }
        guard protocolVersion == Self.version else { throw LocalMacError(Self.restartMessage) }
        guard fingerprint == expected else {
            throw LocalMacError("The Local Mac service update is waiting for active desktops to close. Quit Noodle Computer and reopen it to finish updating; accounts and files are retained.")
        }
        return true
    }
    public static let restartMessage = "The running Local Mac service predates automatic update recovery or is incompatible. Restart your Mac to load the installed helper. If it still cannot start, repair its registration in Local Mac Setup; accounts and files are retained."
}

public enum LocalMacServiceUpdate {
    /// Retry only read-only handshake calls after the daemon has explicitly
    /// announced a restart. Account creation/removal is never replayed.
    public static func waitUntilReady(expected: Data, read: () async throws -> LocalMacServiceInfo,
                                     pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async throws {
        var restarting = false
        for attempt in 0..<12 {
            if attempt > 0 { try await pause() }
            try Task.checkCancellation()
            let info: LocalMacServiceInfo
            do { info = try await read() }
            catch {
                if error is CancellationError { throw error }
                guard restarting else { throw error }
                continue
            }
            if try info.isReady(expected: expected) { return }
            restarting = true
        }
        throw LocalMacError("The Local Mac service has not finished restarting. Retry Start; accounts and approval are retained. If this persists, restart your Mac.")
    }
}
