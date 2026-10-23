import AppKit
import Foundation
import MailBridge

extension MailToolProvider {
    /// The provider as it runs inside Noodle's Mail tool extension: Noodle Mail's signed socket,
    /// starting the app in the background when needed.
    public static func live() -> MailToolProvider {
        let companion = MailCompanion()
        return MailToolProvider { try await companion.call($0) }
    }
}

/// Mirrors the Noodle broker's connection rules: one launch at a time, in the background, and only
/// the exact signed companion for this build.
actor MailCompanion {
    private var launching: Task<Void, Error>?

    func call(_ request: MailRequest) async throws -> MailResponse {
        let socket = try MailConnection.socketURL(), team = try MailConnection.signingTeam()
        do { return try await MailConnection.call(request, socket: socket, team: team) }
        catch let error as MailError where error.unavailable {
            if let launching { try await launching.value }
            else {
                let task = Task { @MainActor in
                    guard let url = MailApplication.locate() else {
                        throw MailError("Install \(MailBuildIdentity.current.appName) to use assigned mailboxes.")
                    }
                    _ = try await MailLaunch.openInBackground(at: url)
                }
                launching = task
                defer { launching = nil }
                try await task.value
            }
            for _ in 0..<40 {
                do { return try await MailConnection.call(request, socket: socket, team: team) }
                catch let error as MailError where error.unavailable { try await Task.sleep(for: .milliseconds(250)) }
            }
            throw MailError("\(MailBuildIdentity.current.appName) did not start in time. Try again in a moment.")
        }
    }
}
