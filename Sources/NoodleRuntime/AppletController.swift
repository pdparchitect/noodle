import AppKit
import AppletBridge
import Foundation
import NoodleCore
import Observation

/// Noodle's side of Noodle Applet: opening noodlets for the person, and the requests the applet
/// tool sends for bots. Noodle Applet trusts this signed process to name the bot a request is for.
@MainActor @Observable public final class AppletController {
    @ObservationIgnored private var agents: [UUID] = []
    @ObservationIgnored private var installed = false
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var launching: Task<Void, Error>?
    @ObservationIgnored private let isInstalled: @Sendable () -> Bool
    @ObservationIgnored private let connection:
        (@Sendable (AppletRequest) async throws -> AppletResponse)?
    @ObservationIgnored private let surface: (@Sendable (AppletRequest) async throws -> SurfaceSocket)?
    /// The bots granted the applet tool: every one of them while Noodle Applet is installed.
    @ObservationIgnored public var onGrantsChange: (([UUID: Set<String>]) -> Void)?
    /// `connection` and `surface` reach Noodle Applet on this Mac unless given.
    public init(
        connection: (@Sendable (AppletRequest) async throws -> AppletResponse)? = nil,
        surface: (@Sendable (AppletRequest) async throws -> SurfaceSocket)? = nil,
        isInstalled: @escaping @Sendable () -> Bool = { AppletApplication.isInstalled(at: AppletApplication.locate()) }
    ) {
        self.connection = connection
        self.surface = surface
        self.isInstalled = isInstalled
    }
    public func start(agents: [AgentRecord]) {
        self.agents = agents.map(\.id)
        refreshSkills(force: true)
        if monitor == nil, !agents.isEmpty {
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    self?.refreshSkills()
                }
            }
        }
    }
    /// Installing or removing the companion grants or withdraws the tool without restarting
    /// harnesses or interrupting their current work.
    public func refreshSkills() { refreshSkills(force: false) }
    private func refreshSkills(force: Bool) {
        let now = isInstalled()
        guard force || now != installed else { return }
        installed = now
        onGrantsChange?(now ? Dictionary(uniqueKeysWithValues: agents.map { ($0, [AppletToolGrant.id]) }) : [:])
    }
    public func openLibrary() async throws {
        guard
            let url = AppletApplication.locate()
        else { throw AppletError("Build or install \(AppletBuildIdentity.current.appName) first.") }
        _ = try await NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    public func resolvePreview(_ url: URL) async throws -> NoodletPreviewAccess {
        let id = try NoodletLink.requireID(in: url)
        var request = AppletRequest(.info)
        request.noodletID = id
        request.includePreview = true
        let response = try await call(request).checked()
        return try NoodletPreviewAccess(response: response, expectedID: id)
    }
    @discardableResult
    public func openNoodlet(_ url: URL) async throws -> AppletResponse {
        let id = try NoodletLink.requireID(in: url)
        var request = AppletRequest(.open)
        request.noodletID = id
        request.mode = "foreground"
        try Task.checkCancellation()
        return try await call(request).checked()
    }
    /// A request of the app itself, trusted by Applet as a local caller. Never on a bot's behalf.
    public func companion(_ request: AppletRequest) async throws -> AppletResponse {
        try await call(request).checked()
    }
    /// A bot's request from the applet tool, which names the bot as its owner. Errors come back
    /// in the response, with whatever session they concern.
    public func tool(_ request: AppletRequest) async throws -> AppletResponse {
        guard !request.operation.isAppOnly, request.owner != nil else { throw AppletError("Unknown command.") }
        try request.keepOutOfSight()
        return try await call(request)
    }
    /// A live view of a noodlet session for a person, never for a bot: video down the socket,
    /// what the person does up it.
    public func companionSurface(_ request: AppletRequest) async throws -> SurfaceSocket {
        do {
            if let surface { return try await surface(request) }
            return try await AppletConnection.openSurface(request, socket: AppletConnection.socketURL(), team: AppletConnection.signingTeam())
        } catch {
            // A Noodle Applet from before live views cannot say why; name the app to update.
            if let listed = try? await call(AppletRequest(.list)), !(listed.features ?? []).contains(SurfaceSocket.feature) {
                throw AppletError("Update \(AppletBuildIdentity.current.appName) to watch it live.")
            }
            throw error
        }
    }
    private func call(_ request: AppletRequest) async throws -> AppletResponse {
        if let connection { return try await connection(request) }
        let socket = try AppletConnection.socketURL()
        let team = try AppletConnection.signingTeam()
        do { return try await AppletConnection.call(request, socket: socket, team: team) } catch let
            error as AppletError where error.unavailable
        {
            if let launching {
                try await launching.value
            } else {
                let task = Task { @MainActor in
                    guard
                        let url = AppletApplication.locate()
                    else {
                        throw AppletError(
                            "Install \(AppletBuildIdentity.current.appName) to run noodlets. See Noodle Settings → Companion Apps."
                        )
                    }
                    try await AppletLaunch.openInBackground(at: url)
                }
                launching = task
                do {
                    try await task.value
                    launching = nil
                } catch {
                    launching = nil
                    throw error
                }
            }
            for _ in 0..<40 {
                do {
                    return try await AppletConnection.call(request, socket: socket, team: team)
                } catch let error as AppletError where error.unavailable {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw AppletError("Noodle Applet did not become ready.")
        }
    }
    deinit { monitor?.cancel() }
}
