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
    func heartbeat()
    /// Only harnesses with voices take calls; the rest keep these defaults.
    func startVoiceCall(_ request: VoiceCallRequest, events: @escaping @MainActor (VoiceCallEvent) -> Void) throws
    func sendToVoiceCall(_ text: String)
    func endVoiceCall()
}

extension AgentRuntimeProcess {
    func notify() { _ = notify(immediately: false) }
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

    public func makeProcess() -> any AgentRuntimeProcess {
        switch provider {
        case .muse:
            return MuseAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) }, onActivity: onActivity)
        case .apple, .fx, .grokBuild, .openCode:
            return ACPAgentProcess(provider: provider, agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) }, onActivity: onActivity)
        case .codex:
            return CodexAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, appsEnabled: appsEnabled, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) }, onActivity: onActivity)
        case .antigravity:
            return AntigravityAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) }, onActivity: onActivity)
        case .claudeCode:
            return ClaudeAgentProcess(agent: agent, executableURL: executableURL, workspaceURL: workspaceURL,
                extendedAccess: extendedAccess, appsEnabled: appsEnabled, recoverInterruptedWork: recoverInterruptedWork,
                onSnapshot: onSnapshot, onHeartbeat: onHeartbeat,
                onUnexpectedTermination: { onUnexpectedTermination($0, $1, $2) }, onActivity: onActivity)
        }
    }
}
