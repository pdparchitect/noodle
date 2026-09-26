import AppKit
import ComputerBridge
import Foundation

extension ComputerToolProvider {
    /// The provider as it runs inside Noodle's Computer tool extension: the companion's
    /// signed socket in the shared group container, starting Noodle Computer when needed.
    public static func live() -> ComputerToolProvider {
        ComputerToolProvider(stagingRoot: liveStagingRoot, transport: liveTransport())
    }
    /// Where the signed socket and file transfers live, in the shared group container.
    public static let liveStagingRoot: @Sendable () throws -> URL = { try ComputerConnection.socketURL().deletingLastPathComponent() }
    /// The signed socket, starting Noodle Computer when needed.
    public static func liveTransport() -> Transport {
        let companion = ComputerCompanion()
        return { try await companion.call($0) }
    }
}

/// Mirrors the Noodle broker's connection rules: one quiet launch at a time, and only
/// connection failures are retried. A sent change with an uncertain result is never repeated.
actor ComputerCompanion {
    private var launching: Task<Void, Error>?

    func call(_ request: ComputerRequest) async throws -> ComputerResponse {
        let socket = try ComputerConnection.socketURL(), team = try ComputerConnection.signingTeam()
        do { return try await ComputerConnection.call(request, socket: socket, team: team) }
        catch let error as ComputerBridgeError where error.unavailable {
            if let launching { try await launching.value }
            else {
                let task = Task { @MainActor in
                    guard let url = ComputerApplication.locate() else {
                        throw ComputerBridgeError("Install \(ComputerBuildIdentity.current.appName) to use computers with your bots.")
                    }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false; configuration.hides = true
                    configuration.allowsRunningApplicationSubstitution = false
                    configuration.arguments = ["--noodle-background"]
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }
                launching = task
                defer { launching = nil }
                try await task.value
            }
            for attempt in 0..<40 {
                do { return try await ComputerConnection.call(request, socket: socket, team: team) }
                catch let error as ComputerBridgeError where error.unavailable && attempt < 39 { try await Task.sleep(for: .milliseconds(250)) }
            }
            throw ComputerBridgeError("Computer did not become ready.")
        }
    }
}
