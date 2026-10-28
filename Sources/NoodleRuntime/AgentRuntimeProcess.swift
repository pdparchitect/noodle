import Foundation
import NoodleCore


@MainActor
public protocol AgentRuntimeProcess: AnyObject {
    var configuration: AgentRecord { get }
    var snapshot: AgentRuntimeSnapshot { get }
    var isAlive: Bool { get }
    var hasInterruptedWork: Bool { get }
    var canReceiveHeartbeat: Bool { get }
    func start()
    func stop(completion: @escaping (Bool) -> Void)
    @discardableResult func notify(immediately: Bool) -> UUID
    func promoteNotification(_ id: UUID)
    /// The pending message asks the bot to stop. Harnesses that can add it to the running turn take it like any
    /// urgent message, and the bot decides what to stop.
    func requestStop(_ id: UUID)
    func heartbeat()
    /// Starts a turn for a wake the bot scheduled, when it can take one like a heartbeat.
    func wake()
    /// Starts a turn asking the bot to tidy its own workspace files, when it can take one like a heartbeat.
    func organize()
    /// Only harnesses with voices take calls; the rest keep these defaults.
    func startVoiceCall(_ request: VoiceCallRequest, events: @escaping @MainActor (VoiceCallEvent) -> Void) throws
    func sendToVoiceCall(_ text: String)
    func endVoiceCall()
}

extension AgentRuntimeProcess {
    func notify() { _ = notify(immediately: false) }
    public func requestStop(_ id: UUID) { promoteNotification(id) }
    public func startVoiceCall(_ request: VoiceCallRequest, events: @escaping @MainActor (VoiceCallEvent) -> Void) throws {
        throw VoiceCallUnavailable()
    }
    public func sendToVoiceCall(_ text: String) {}
    public func endVoiceCall() {}
}

/// Construction is injected after workspace and access checks, so tests exercise
/// the same coordinator policy without launching a harness or an XPC helper.
@MainActor
public struct AgentRuntimeLaunch {
    public let agent: AgentRecord
    let provider: HarnessProvider
    let executableURL: URL
    let workspaceURL: URL
    let extendedAccess: Bool
    let appsEnabled: Bool
    let recoverInterruptedWork: Bool
    public let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    let onHeartbeat: @MainActor () -> Void
    let onUnexpectedTermination: @MainActor (any AgentRuntimeProcess, String, Bool) -> Void
    var onActivity: @MainActor ([String: Any]) -> Void = { _ in }

    /// Only temporary fallback launches override the saved profile. The host resolves this UUID itself.
    public var profileOverride: UUID? = nil

    public func makeProcess() -> any AgentRuntimeProcess {
        let connect: @MainActor () throws -> ExtendedAgentConnection = {
            let connection = try ExtendedAgentConnection()
            connection.profileOverride = profileOverride
            return connection
        }
        switch provider {
        case .muse:
            return MuseAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) },
                onActivity: onActivity, makeConnection: { try connect() })
        case .apple, .fx, .grokBuild, .openCode:
            return ACPAgentProcess(provider: provider, agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) },
                onActivity: onActivity, makeConnection: { try connect() })
        case .codex:
            return CodexAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, appsEnabled: appsEnabled, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) },
                onActivity: onActivity, makeConnection: { try connect() })
        case .antigravity:
            return AntigravityAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) },
                onActivity: onActivity, makeConnection: { try connect() })
        case .claudeCode:
            return ClaudeAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, appsEnabled: appsEnabled, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) },
                onActivity: onActivity, makeConnection: { try connect() })
        }
    }
}

extension AgentRuntimeProcess {
    /// A bot sets its own status line while it runs; that is not a change to how it runs.
    func runs(_ agent: AgentRecord) -> Bool {
        var started = configuration
        started.status = agent.status
        return started == agent
    }
}
