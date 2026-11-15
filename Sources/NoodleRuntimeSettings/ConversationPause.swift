import NoodleCore
import NoodleRuntime
import SwiftUI

/// Why a conversation's bots don't answer for now, in every app: who waits for Kick or a sign-in, who is suspended,
/// and the one action that brings the first of them back.
public struct ConversationPause: Equatable {
    public enum Action: Equatable {
        /// Only signing in brings it back.
        case signIn(AgentRecord)
        case unsuspend(AgentRecord)
        case kick(AgentRecord)
    }

    /// A bot's own conversation says why it waits; a group names the bots that wait.
    public let summary: String
    public let detail: String?
    public let action: Action?

    /// `waitsForKick` is true for a failed bot this app runs. `heldElsewhere` names another reason a bot does not
    /// answer, such as a Hub's limit. Suspending was deliberate, so `namingSuspended` false leaves suspended bots out
    /// of a group's summary, as a sidebar row does.
    @MainActor public static func of(_ conversation: BotConversation, participants: [AgentRecord], runtime: AgentRuntimeCoordinator,
                                     waitsForKick: (AgentRecord) -> Bool, canUnsuspend: (AgentRecord) -> Bool,
                                     heldElsewhere: (AgentRecord) -> (summary: String, detail: String?)? = { _ in nil },
                                     namingSuspended: Bool = true) -> ConversationPause? {
        let waiting = participants.filter { waitsForKick($0) && runtime.snapshot(for: $0.id).phase == .failed }
        let paused = participants.filter { agent in
            waiting.contains { $0.id == agent.id } || agent.isSuspended() || heldElsewhere(agent) != nil
        }
        guard let first = paused.first else { return nil }
        let summary: String
        if conversation.kind == .group {
            let named = namingSuspended ? paused : paused.filter { !$0.isSuspended() }
            guard !named.isEmpty else { return nil }
            summary = "Paused: " + named.map(\.displayName).joined(separator: ", ")
        } else if first.isSuspended(), let until = first.suspendedUntil {
            summary = AgentRecord.suspension(until: until)
        } else if waiting.contains(where: { $0.id == first.id }), let reason = runtime.snapshot(for: first.id).pauseSummary {
            summary = reason
        } else if let held = heldElsewhere(first) {
            summary = held.summary
        } else { return nil }
        var detail = waiting.first.map { runtime.snapshot(for: $0.id).detail }
        if detail == nil { detail = paused.compactMap { heldElsewhere($0)?.detail }.first }
        let action: Action?
        if let agent = waiting.first, runtime.snapshot(for: agent.id).failure == .authenticationRequired {
            action = .signIn(agent)
        } else if let agent = participants.first(where: { $0.isSuspended() && canUnsuspend($0) }) {
            action = .unsuspend(agent)
        } else if let agent = waiting.first {
            action = .kick(agent)
        } else { action = nil }
        return ConversationPause(summary: summary, detail: detail, action: action)
    }
}

/// Over a conversation while one of its bots waits: why, in a few words, and Sign In, Unsuspend or Kick. In a group,
/// it acts on the first bot that waits; the next shows once it is back. It sits in the toolbar, so its window presents
/// the Kick alert: see `AgentKickConfirmation`.
public struct ConversationPauseBar: View {
    let pause: ConversationPause
    let runtime: AgentRuntimeCoordinator
    let signIn: () -> Void
    let unsuspend: (AgentRecord) -> Void
    let kick: (AgentRecord) -> Void

    public init(pause: ConversationPause, runtime: AgentRuntimeCoordinator, signIn: @escaping () -> Void,
                unsuspend: @escaping (AgentRecord) -> Void, kick: @escaping (AgentRecord) -> Void) {
        self.pause = pause
        self.runtime = runtime
        self.signIn = signIn
        self.unsuspend = unsuspend
        self.kick = kick
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(pause.summary)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(pause.detail ?? pause.summary)
            switch pause.action {
            case .signIn(let agent):
                Button("Sign In…", action: signIn)
                    .help("Sign in to the harness \(agent.displayName) uses")
            case .unsuspend(let agent):
                Button("Unsuspend") { unsuspend(agent) }
                    .help("Let \(agent.displayName) take new turns again")
            case .kick(let agent):
                Button("Kick") { kick(agent) }
                    .disabled(runtime.changingAccess.contains(agent.id))
                    .help("Kick \(agent.displayName)")
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 6)
    }
}
