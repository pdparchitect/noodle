import AppKit
import NoodleCore
import SwiftUI

/// Calls bots place with `messenger --call`. They ring in a panel until the person answers or
/// declines, or until they expire; only answering connects to the bot's voice. A bot on this Mac
/// rings here, and on the owner's devices while this Mac serves them as a Hub; a Hub holds its own
/// bots' calls and rings them on every device of their owner.
extension NoodleStore {
    /// Rings the call a bot on this Mac placed, or leaves it as missed when it can no longer ring.
    func ringCall(of agentID: UUID, now: Date = Date()) {
        guard let request = repository.pendingCall(agentID: agentID),
              !ringingCalls.contains(where: { $0.id == request.id }) else { return }
        // Someone on a call is not rung; the call is left as missed and the bot writes instead.
        guard request.expiresAt > now, voiceCalls.call == nil, runsHere(agentID),
              let conversation = conversations.first(where: { $0.id == request.conversationID }),
              voiceCallTarget(for: conversation)?.id == agentID else {
            return endUnansweredCall(request, .missed, at: now)
        }
        ring(request)
        thisMac.ringCall(of: agentID, now: now)
    }

    /// Rings a call a bot on a Hub placed, with the bot and conversation here. The Hub says when it stops.
    func ringHubCall(_ request: AgentCallRequest, now: Date = Date()) {
        guard !ringingCalls.contains(where: { $0.id == request.id }), request.expiresAt > now,
              !runsHere(request.agentID), voiceCalls.call == nil, isCallable(request.agentID) else { return }
        ring(request)
    }

    /// Stops ringing a call answered or declined elsewhere, or that the Hub left as missed.
    func stopRinging(_ id: UUID) { _ = takeRingingCall(id) }

    private func ring(_ request: AgentCallRequest) {
        ringingCalls.append(request)
        guard connectsServices else { return }
        IncomingCallPanel.shared.update(self)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow)))
            self?.expireCalls(at: Date())
        }
    }

    /// Ends quietly the calls of bots deleted or archived while they rang: there is nobody left to answer.
    func dropCallsOfGoneBots() {
        for request in ringingCalls where !isCallable(request.agentID) {
            _ = takeRingingCall(request.id)
            _ = try? repository.endCall(agentID: request.agentID, id: request.id)
        }
    }

    func isCallable(_ agentID: UUID) -> Bool { agents.contains { $0.id == agentID && $0.archivedAt == nil } }

    /// Ends the calls that rang for too long as missed. A Hub's are left to the Hub, which keeps them.
    func expireCalls(at now: Date) {
        for request in ringingCalls where request.expiresAt <= now {
            if runsHere(request.agentID) { endUnansweredCall(request, .missed, at: now) } else { stopRinging(request.id) }
        }
    }

    /// Answering is calling the bot, told why it called, in the window that shows its conversation.
    func answerCall(_ id: UUID, media: (any VoiceCallMedia)? = nil) {
        // Answering never hangs up a call in progress; this one rings on until it is missed.
        guard voiceCalls.call == nil else { return }
        guard let request = takeRingingCall(id),
              let conversation = conversations.first(where: { $0.id == request.conversationID }) else { return }
        if runsHere(request.agentID) {
            guard (try? repository.endCall(agentID: request.agentID, id: id)) != nil else { return }
            startVoiceCall(in: conversation, media: media, answeredCallReason: request.reason)
        } else {
            // The Hub checks the call still rings and tells the bot why it called.
            startVoiceCall(in: conversation, media: media, answeredCallID: id)
        }
        guard connectsServices else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !conversationWindows.focus(conversation.id) {
            selectedConversationID = conversation.id
            conversationWindows.showMainWindow()
        }
    }

    func declineCall(_ id: UUID) {
        guard let request = ringingCalls.first(where: { $0.id == id }) else { return }
        guard !runsHere(request.agentID) else { return endUnansweredCall(request, .declined, at: Date()) }
        stopRinging(id)
        guard let mirror = hubMirror(forAgent: request.agentID) else { return }
        Task { [weak self] in
            do { try await mirror.declineCall(id) } catch { self?.errorMessage = "Could not decline the call: \(error.localizedDescription)" }
        }
    }

    /// Leaves the card in the conversation, which shows it unread, and tells the bot, once per call.
    private func endUnansweredCall(_ request: AgentCallRequest, _ outcome: UnansweredCall, at now: Date) {
        _ = takeRingingCall(request.id)
        guard isCallable(request.agentID) else {
            _ = try? repository.endCall(agentID: request.agentID, id: request.id)
            return
        }
        guard (try? repository.endCall(agentID: request.agentID, id: request.id)) != nil else { return }
        do {
            try repository.recordUnansweredCall(request, outcome, at: now)
        } catch {
            errorMessage = "Could not add the missed call to the conversation: \(error.localizedDescription)"
        }
        refreshTranscripts()
        guard let agent = agents.first(where: { $0.id == request.agentID }) else { return }
        let personName = (try? repository.loadAgentOwner(agent))?.name ?? "Your person"
        runtime.wake(agent.id, note: AgentCallDocumentation.unansweredNote(outcome, personName: personName, reason: request.reason,
                                                                          conversationID: request.conversationID),
                     repository: repository)
    }

    private func takeRingingCall(_ id: UUID) -> AgentCallRequest? {
        // Answered, declined or missed here, or ended before it rang here: the owner's devices stop too.
        thisMac.stopRinging(id)
        guard let index = ringingCalls.firstIndex(where: { $0.id == id }) else { return nil }
        let request = ringingCalls.remove(at: index)
        if connectsServices { IncomingCallPanel.shared.update(self) }
        return request
    }
}

extension NoodleStore: VoiceCallHost, IncomingCallHost {
    func startCall(in conversation: BotConversation) { startVoiceCall(in: conversation) }
    func callerName(_ agentID: UUID) -> String? { agents.first { $0.id == agentID }?.displayName }
    func caller(_ agentID: UUID) -> AgentRecord? { agents.first { $0.id == agentID } }
    func answer(_ id: UUID) { answerCall(id) }
    func decline(_ id: UUID) { declineCall(id) }
    func callerPicture(_ agent: AgentRecord) -> AnyView { AnyView(ConversationAvatar(participants: [agent], isGroup: false, size: 44)) }
    func ring(_ call: AgentCallRequest, from agent: AgentRecord) { NoodleNotifications.ring(call, from: agent) }
    func stopRingingNotification() { NoodleNotifications.stopRinging() }
}
