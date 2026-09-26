import AppKit
import BrowserBridge
import Foundation

extension BrowserToolProvider {
    /// The provider as it runs inside Noodle's Browser tool extension: the companion's
    /// signed socket in the shared group container, starting Noodle Browser when needed.
    public static func live() -> BrowserToolProvider {
        BrowserToolProvider(stagingRoot: liveStagingRoot, transport: liveTransport())
    }
    /// Where the signed socket and file transfers live, in the shared group container.
    public static let liveStagingRoot: @Sendable () throws -> URL = { try BrowserConnection.socketURL().deletingLastPathComponent() }
    /// The signed socket, starting Noodle Browser when needed.
    public static func liveTransport() -> Transport {
        let companion = BrowserCompanion()
        return { try await companion.call($0) }
    }
}

/// Mirrors the Noodle broker's connection rules: one launch at a time, in the
/// background, and only the exact signed companion for this build channel.
actor BrowserCompanion {
    private var launching: Task<Void, Error>?

    func call(_ request: BrowserRequest) async throws -> BrowserResponse {
        let socket = try BrowserConnection.socketURL(), team = try BrowserConnection.signingTeam()
        do { return try await BrowserConnection.call(request, socket: socket, team: team) }
        catch let error as BrowserError where error.unavailable {
            if let launching { try await launching.value }
            else {
                let task = Task { @MainActor in
                    guard let url = BrowserApplication.locate() else {
                        throw BrowserError("Install \(BrowserBuildIdentity.current.appName) to use assigned browsers.")
                    }
                    _ = try await BrowserLaunch.openInBackground(at: url)
                }
                launching = task
                defer { launching = nil }
                try await task.value
            }
            for _ in 0..<40 {
                do { return try await BrowserConnection.call(request, socket: socket, team: team) }
                catch let error as BrowserError where error.unavailable { try await Task.sleep(for: .milliseconds(250)) }
            }
            throw BrowserError("Noodle Browser did not become ready.")
        }
    }
}
