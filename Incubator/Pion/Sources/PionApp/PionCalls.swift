import AppKit
import HubLink
import NoodleCore
import NoodleRuntime
import SwiftUI

/// Voice calls with agents, as in Noodle: the champion calls an agent whose harness has voices, and an agent
/// places a call with `messenger --call`, which rings until it is answered, declined or missed. One call at a
/// time; its card and what was said go into the agent's conversation.
@MainActor @Observable final class PionCalls: VoiceCallHost, IncomingCallHost {
    private let model: PionModel
    /// Shows a conversation, for a call answered from the ringing panel.
    @ObservationIgnored var open: (UUID) -> Void = { _ in }
    private(set) var ringingCalls: [AgentCallRequest] = []
    @ObservationIgnored private let guesser: any VoicePresentationGuessing = AppleVoicePresentationGuesser()

    @ObservationIgnored lazy var voiceCalls = VoiceCallController(
        router: VoiceCallRouter(local: model.runtime, isOnHub: { _ in false }, openHubCall: { _, _ in throw VoiceCallUnavailable() }),
        makeMedia: { EngineVoiceCallMedia() }, report: { [weak self] in self?.model.problem = $0 },
        record: { [weak self] in self?.record($0) },
        finish: { [weak self] in self?.finish($0, messageID: $1, endedAt: $2) })

    init(model: PionModel) {
        self.model = model
        guard !model.isScripted else { return }
        // The agent reads chat messages through its inbox; the voice hears about them here.
        model.onSent = { [weak self] id, body, files in self?.voiceCalls.shared(in: id, body: body, attachmentNames: files) }
        model.handleCallRequests { [weak self] id in Task { @MainActor in self?.ringCall(of: id) } }
    }

    // MARK: Calling

    /// Calls are one-to-one with an agent whose harness has voices. It need not be running: calling starts it.
    func voiceCallTarget(for conversation: BotConversation) -> AgentRecord? {
        guard !model.isScripted, conversation.kind == .direct, let agent = model.agent(conversation.participantIDs.first),
              HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.voices.isEmpty == false else { return nil }
        return agent
    }

    func canCallNow(in conversation: BotConversation) -> Bool { voiceCallTarget(for: conversation) != nil }

    func startCall(in conversation: BotConversation) { start(in: conversation, answeredCallReason: nil) }

    /// There is one call at a time, so this ends it from any window; otherwise it calls the conversation's agent.
    func toggleCall(in conversationID: UUID?) {
        if voiceCalls.call != nil { return voiceCalls.hangUp() }
        if let conversation = model.conversation(conversationID) { startCall(in: conversation) }
    }

    private func start(in conversation: BotConversation, answeredCallReason: String?) {
        guard let agent = voiceCallTarget(for: conversation) else { return }
        let recentLines = model.messages(in: conversation.id).suffix(12).compactMap { message -> VoiceCallLine? in
            guard message.call == nil else { return nil }
            switch message.author {
            case .user: return .init(.person, message.body)
            case .agent: return .init(.bot, message.body)
            case .system: return nil
            }
        }
        model.runtime.start(agent: agent, repository: model.repository)
        let identity = (try? model.repository.loadAgentBackstory(agent)).map {
            VoiceCallIdentity(name: agent.displayName, description: agent.publicDescription, backstory: $0)
        }
        let personName = model.champion
        Task {
            let voice = await BotVoice.forCall(agent, repository: model.repository, guesser: guesser)
            voiceCalls.start(agentID: agent.id, conversationID: conversation.id, voice: voice, personName: personName,
                             identity: identity, recentLines: recentLines, answeredCallReason: answeredCallReason)
        }
    }

    /// The card of the call in progress in a conversation, once it connected.
    func liveCallCardID(in conversationID: UUID) -> UUID? {
        guard let call = voiceCalls.call, call.conversationID == conversationID else { return nil }
        return call.messageID
    }

    func callerName(_ agentID: UUID) -> String? { caller(agentID)?.displayName }

    private func record(_ call: VoiceCallController.Call) -> UUID? {
        do {
            let message = try model.repository.recordVoiceCall(agentID: call.agentID, conversationID: call.conversationID)
            model.refresh()
            model.markRead(call.conversationID)
            return message.id
        } catch {
            model.problem = "Could not add the call to the conversation: \(error.localizedDescription)"
            return nil
        }
    }

    private func finish(_ call: VoiceCallController.Call, messageID: UUID, endedAt: Date) {
        do {
            _ = try model.repository.finishVoiceCall(messageID: messageID, conversationID: call.conversationID,
                                                     lines: call.lines, endedAt: endedAt)
            model.refresh()
        } catch {
            model.problem = "Could not save the call's transcript: \(error.localizedDescription)"
        }
    }

    // MARK: Ringing

    func isCallable(_ agentID: UUID) -> Bool { model.agent(agentID) != nil }
    func caller(_ agentID: UUID) -> AgentRecord? { model.everyAgent.first { $0.id == agentID } }
    func callerPicture(_ agent: AgentRecord) -> AnyView { AnyView(AgentMark(agent: agent, size: 44)) }
    func ring(_ call: AgentCallRequest, from agent: AgentRecord) { AgentNotifications.ring(call, from: agent) }
    func stopRingingNotification() { AgentNotifications.stopRinging() }

    /// Rings a call an agent placed, or leaves it as missed when it can no longer ring.
    func ringCall(of agentID: UUID, now: Date = Date()) {
        guard let request = model.repository.pendingCall(agentID: agentID),
              !ringingCalls.contains(where: { $0.id == request.id }) else { return }
        // Someone on a call is not rung; the call is left as missed and the agent writes instead.
        guard request.expiresAt > now, voiceCalls.call == nil, let conversation = model.conversation(request.conversationID),
              voiceCallTarget(for: conversation)?.id == agentID else {
            return endUnansweredCall(request, .missed, at: now)
        }
        ringingCalls.append(request)
        IncomingCallPanel.shared.update(self)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow)))
            self?.expireCalls(at: Date())
        }
    }

    private func expireCalls(at now: Date) {
        for request in ringingCalls where request.expiresAt <= now { endUnansweredCall(request, .missed, at: now) }
    }

    /// Answering is calling the agent, told why it called, in the window that shows its conversation.
    func answer(_ id: UUID) {
        // Answering never hangs up a call in progress; this one rings on until it is missed.
        guard voiceCalls.call == nil, let request = takeRingingCall(id),
              let conversation = model.conversation(request.conversationID),
              (try? model.repository.endCall(agentID: request.agentID, id: id)) != nil else { return }
        start(in: conversation, answeredCallReason: request.reason)
        NSApp.activate(ignoringOtherApps: true)
        open(conversation.id)
    }

    func decline(_ id: UUID) {
        guard let request = ringingCalls.first(where: { $0.id == id }) else { return }
        endUnansweredCall(request, .declined, at: Date())
    }

    /// Leaves the card in the conversation and tells the agent, once per call.
    private func endUnansweredCall(_ request: AgentCallRequest, _ outcome: UnansweredCall, at now: Date) {
        _ = takeRingingCall(request.id)
        guard (try? model.repository.endCall(agentID: request.agentID, id: request.id)) != nil, isCallable(request.agentID) else { return }
        do {
            _ = try model.repository.recordUnansweredCall(request, outcome, at: now)
        } catch {
            model.problem = "Could not add the missed call to the conversation: \(error.localizedDescription)"
        }
        model.refresh()
        model.runtime.wake(request.agentID, note: AgentCallDocumentation.unansweredNote(outcome, personName: model.champion,
                                                                                       reason: request.reason, conversationID: request.conversationID),
                           repository: model.repository)
    }

    private func takeRingingCall(_ id: UUID) -> AgentCallRequest? {
        guard let index = ringingCalls.firstIndex(where: { $0.id == id }) else { return nil }
        let request = ringingCalls.remove(at: index)
        IncomingCallPanel.shared.update(self)
        return request
    }
}
