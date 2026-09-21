import Foundation
import NoodleCore

/// Testable transport boundary around the signed helper. Access selection stays
/// here so injected connections cannot change the shipped launch policy.
@MainActor protocol HarnessRuntimeConnection: RuntimeStopConnection {
    var onData: ((Data, Bool) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func startHarness(provider: HarnessProvider, agentID: UUID, executablePath: String,
                      extendedAccess: Bool, appsEnabled: Bool, sessionID: UUID?, resumeSession: Bool,
                      modelIdentifier: String?, effortIdentifier: String?,
                      reply: @escaping (Int32, String?) -> Void)
    func write(_ data: Data)
    func invalidate()
}

extension ExtendedAgentConnection: HarnessRuntimeConnection {
    @MainActor func startHarness(provider: HarnessProvider, agentID: UUID, executablePath: String,
                                extendedAccess: Bool, appsEnabled: Bool, sessionID: UUID?, resumeSession: Bool,
                                modelIdentifier: String?, effortIdentifier: String?,
                                reply: @escaping (Int32, String?) -> Void) {
        if extendedAccess {
            start(provider: provider, agentID: agentID, executablePath: executablePath,
                  sessionID: sessionID, resumeSession: resumeSession,
                  modelIdentifier: modelIdentifier, effortIdentifier: effortIdentifier, appsEnabled: appsEnabled, reply: reply)
        } else {
            switch provider {
            case .codex:
                startRestrictedCodex(agentID: agentID, executablePath: executablePath, appsEnabled: appsEnabled, reply: reply)
            case .claudeCode:
                startRestrictedClaude(agentID: agentID, executablePath: executablePath,
                    sessionID: sessionID, resumeSession: resumeSession, modelIdentifier: modelIdentifier,
                    effortIdentifier: effortIdentifier, appsEnabled: appsEnabled, reply: reply)
            case .apple:
                startRestrictedApple(agentID: agentID, modelIdentifier: modelIdentifier, reply: reply)
            case .antigravity:
                startRestrictedAntigravity(agentID: agentID, executablePath: executablePath,
                    conversationID: resumeSession ? sessionID : nil, modelIdentifier: modelIdentifier, reply: reply)
            case .fx, .grokBuild, .openCode:
                startRestrictedACP(provider: provider, agentID: agentID, executablePath: executablePath,
                                   modelIdentifier: modelIdentifier, effortIdentifier: effortIdentifier, reply: reply)
            default:
                reply(0, "This harness requires unrestricted access.")
            }
        }
    }
}
