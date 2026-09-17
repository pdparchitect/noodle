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
            throw LocalMacError("The running Local Mac service belongs to a different build. Close this build’s active desktops and reopen it after updating. Use Noodle Computer Dev for development alongside the installed app; accounts and files are retained.")
        }
        return true
    }
    public static let restartMessage = "The running Local Mac service predates automatic update recovery or is incompatible. Restart your Mac to load the installed helper. If it still cannot start, repair its registration in Local Mac Setup; accounts and files are retained."
}

public enum LocalMacServiceUpdate {
    /// Retry only the read-only handshake. An updated app can receive a
    /// transport/authentication failure before it can read the old daemon's
    /// restart reply: its previous executable may already have been unlinked.
    /// Keep signature checks in force and wait for a verified replacement.
    /// Account creation/removal is never replayed.
    public static func waitUntilReady(expected: Data, read: () async throws -> LocalMacServiceInfo,
                                     pause: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        for attempt in 0..<12 {
            if attempt > 0 { try await pause() }
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { break }
            let info: LocalMacServiceInfo
            do { info = try await read() }
            catch is LocalMacServiceUnavailable { continue }
            if try info.isReady(expected: expected) { return }
        }
        throw LocalMacServiceUnavailable()
    }
}

/// No trusted handshake response arrived. This is distinct from an explicit
/// service failure, incompatible protocol, or verified but different image.
public struct LocalMacServiceUnavailable: Error, Sendable {
    public init() {}
}
