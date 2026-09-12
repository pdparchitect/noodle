import Foundation

/// Conversations each bot is expected to answer. Wakes carry no conversation,
/// so the app records where it notified a bot and shows typing only there.
public struct AgentTypingTracker: Equatable, Sendable {
    private var conversations: [UUID: Set<UUID>] = [:]
    /// Hidden after a reply; the token lets only the latest reply resume it.
    private var paused: [UUID: [UUID: UUID]] = [:]

    public init() {}

    public mutating func expectReply(from agentIDs: some Sequence<UUID>, in conversationID: UUID) {
        for id in agentIDs {
            conversations[id, default: []].insert(conversationID)
            paused[id]?[conversationID] = nil
        }
    }

    /// Harnesses finish their turn a moment after the reply lands, so hide
    /// typing with the reply and resume it only if the bot keeps working.
    public mutating func pause(_ agentID: UUID, in conversationID: UUID) -> UUID? {
        guard conversations[agentID]?.contains(conversationID) == true else { return nil }
        let token = UUID()
        paused[agentID, default: [:]][conversationID] = token
        return token
    }

    public mutating func resume(_ agentID: UUID, in conversationID: UUID, token: UUID) {
        guard paused[agentID]?[conversationID] == token else { return }
        paused[agentID]?[conversationID] = nil
    }

    /// Drivers report `ready` before starting a queued turn, so pending work
    /// keeps the expectation alive for the turn that follows.
    public mutating func update(_ snapshot: AgentRuntimeSnapshot, hasPendingWork: Bool) {
        guard !snapshot.phase.isBusy else { return }
        paused[snapshot.agentID] = nil
        if !hasPendingWork { conversations[snapshot.agentID] = nil }
    }

    public mutating func remove(_ agentID: UUID) {
        conversations[agentID] = nil
        paused[agentID] = nil
    }

    public func isTyping(_ agentID: UUID, in conversationID: UUID, phase: AgentRuntimePhase) -> Bool {
        phase.isBusy && conversations[agentID]?.contains(conversationID) == true
            && paused[agentID]?[conversationID] == nil
    }
}

extension AgentRuntimePhase {
    var isBusy: Bool { self == .starting || self == .working }
}
