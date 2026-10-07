import Foundation
import NoodleCore
import HubLink
import WebKit
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class VoiceCallRuntimeFake: VoiceCallRuntime {
    var requests: [(agentID: UUID, request: VoiceCallRequest)] = []
    var events: (@MainActor (VoiceCallEvent) -> Void)?
    var sent: [String] = []
    var ended: [UUID] = []
    var startError: Error?
    func startVoiceCall(agentID: UUID, _ request: VoiceCallRequest, events: @escaping @MainActor (VoiceCallEvent) -> Void) throws {
        if let startError { throw startError }
        requests.append((agentID, request))
        self.events = events
    }
    func sendToVoiceCall(agentID: UUID, _ text: String) { sent.append(text) }
    func endVoiceCall(agentID: UUID) { ended.append(agentID) }
}

@MainActor final class VoiceCallMediaFake: VoiceCallMedia {
    var onFailure: ((String) -> Void)?
    var offerError: Error?
    var answers: [String] = []
    var muted: [Bool] = []
    var closed = 0
    var connectedAnnouncements = 0
    func prepareOffer() async throws -> String {
        if let offerError { throw offerError }
        return "offer-sdp"
    }
    func accept(answer: String) async throws { answers.append(answer) }
    func setMuted(_ muted: Bool) { self.muted.append(muted) }
    func close() { closed += 1 }
    func announceConnected() { connectedAnnouncements += 1 }
}

@MainActor final class VoiceGuesserFake: VoicePresentationGuessing {
    let answers: [String: VoicePresentation]?
    init(_ answers: [String: VoicePresentation]?) { self.answers = answers }
    func presentation(forName name: String) async -> VoicePresentation? { answers?[name] }
}

@MainActor final class VoiceCallChannelFake: VoiceCallChannel {
    let frames: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var cancelled = 0
    init() { (frames, continuation) = AsyncThrowingStream.makeStream() }
    func push(_ event: LinkCallEvent) { continuation.yield(event.encoded) }
    nonisolated func cancel() { MainActor.assumeIsolated { cancelled += 1; continuation.finish(throwing: CancellationError()) } }
}

private struct FixtureError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor final class VoiceCallTests: XCTestCase {
    private var runtime = VoiceCallRuntimeFake()
    private var media: [VoiceCallMediaFake] = []
    private var reports: [String] = []
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func controller() -> VoiceCallController {
        VoiceCallController(runtime: runtime, makeMedia: { [unowned self] in
            let next = VoiceCallMediaFake(); media.append(next); return next
        }, report: { [unowned self] in reports.append($0) }, now: { [date] in date })
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate())
    }

    func testCallConnectsThroughMediaAndRuntimeAndShowsSpokenLines() async throws {
        let calls = controller(), agentID = UUID(), conversationID = UUID()
        calls.start(agentID: agentID, conversationID: conversationID, voice: "cove", personName: "Alex",
                    recentLines: [.init(.person, "Hello")])
        XCTAssertEqual(calls.call?.conversationID, conversationID)
        XCTAssertNil(calls.call?.startedAt)
        try await wait { runtime.requests.count == 1 }
        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertEqual(request.agentID, agentID)
        XCTAssertEqual(request.request.offer, "offer-sdp")
        XCTAssertEqual(request.request.voice, "cove")
        XCTAssertEqual(request.request.conversationID, conversationID)
        XCTAssertEqual(request.request.personName, "Alex")
        XCTAssertEqual(request.request.recentLines, [.init(.person, "Hello")])

        runtime.events?(.answer("answer-sdp"))
        try await wait { media.first?.answers == ["answer-sdp"] }
        XCTAssertEqual(media.first?.connectedAnnouncements, 0)
        runtime.events?(.started)
        runtime.events?(.started)
        XCTAssertEqual(media.first?.connectedAnnouncements, 1)
        runtime.events?(.line(.init(.person, "Is the build green?")))
        runtime.events?(.line(.init(.bot, "Checking.")))
        XCTAssertEqual(calls.call?.startedAt, date)
        // Each line is stamped when it was said, so it can sit among what was typed meanwhile.
        XCTAssertEqual(calls.call?.lines, [.init(.person, "Is the build green?", at: date), .init(.bot, "Checking.", at: date)])

        calls.toggleMute()
        XCTAssertEqual(calls.call?.isMuted, true)
        XCTAssertEqual(media.first?.muted, [true])

        calls.shared(in: conversationID, body: "Here is the log", attachmentNames: ["build.log"])
        calls.shared(in: UUID(), body: "Elsewhere", attachmentNames: [])
        XCTAssertEqual(runtime.sent, [VoiceCallDocumentation.typedMessage(body: "Here is the log", attachmentNames: ["build.log"])])

        calls.hangUp()
        XCTAssertNil(calls.call)
        XCTAssertEqual(runtime.ended, [agentID])
        XCTAssertEqual(media.first?.closed, 1)
        runtime.events?(.ended(nil))
        XCTAssertEqual(reports, [])
    }

    func testFailuresEndTheCallAndAreReported() async throws {
        let calls = controller()
        runtime.startError = FixtureError("This bot cannot take calls right now.")
        calls.start(agentID: UUID(), conversationID: UUID(), voice: "cove", personName: "Alex", recentLines: [])
        try await wait { calls.call == nil }
        XCTAssertEqual(reports, ["This bot cannot take calls right now."])
        XCTAssertEqual(media.last?.closed, 1)

        runtime.startError = nil
        calls.start(agentID: UUID(), conversationID: UUID(), voice: "cove", personName: "Alex", recentLines: [])
        try await wait { runtime.requests.count == 1 }
        runtime.events?(.ended("The bot stopped."))
        XCTAssertNil(calls.call)
        XCTAssertEqual(media.last?.closed, 1)
        XCTAssertEqual(reports.last, "The bot stopped.")

        calls.start(agentID: UUID(), conversationID: UUID(), voice: "cove", personName: "Alex", recentLines: [])
        try await wait { runtime.requests.count == 2 }
        media.last?.onFailure?("The call connection was lost.")
        XCTAssertNil(calls.call)
        XCTAssertEqual(runtime.ended.count, 1)
        XCTAssertEqual(reports.last, "The call connection was lost.")
    }

    func testMicrophoneFailureNeverStartsTheRuntimeSide() async throws {
        let calls = VoiceCallController(runtime: runtime, makeMedia: { [unowned self] in
            let next = VoiceCallMediaFake(); next.offerError = FixtureError("Microphone access is off."); media.append(next); return next
        }, report: { [unowned self] in reports.append($0) }, now: { [date] in date })
        calls.start(agentID: UUID(), conversationID: UUID(), voice: "cove", personName: "Alex", recentLines: [])
        try await wait { calls.call == nil }
        XCTAssertEqual(runtime.requests.count, 0)
        XCTAssertEqual(reports, ["Microphone access is off."])
        XCTAssertEqual(media.first?.closed, 1)
    }

    func testANewCallReplacesTheCurrentOne() async throws {
        let calls = controller(), first = UUID(), second = UUID()
        calls.start(agentID: first, conversationID: UUID(), voice: "cove", personName: "Alex", recentLines: [])
        try await wait { runtime.requests.count == 1 }
        calls.start(agentID: second, conversationID: UUID(), voice: "cove", personName: "Alex", recentLines: [])
        XCTAssertEqual(runtime.ended, [first])
        XCTAssertEqual(media.first?.closed, 1)
        try await wait { runtime.requests.count == 2 }
        XCTAssertEqual(calls.call?.agentID, second)
    }

    func testCodexOffersItsVoicesGroupedByHowTheySoundAndOtherHarnessesNone() {
        let voices = HarnessProvider.codex.voices
        XCTAssertEqual(voices.filter { $0.presentation == .feminine }.map(\.id), ["juniper", "maple", "sol", "vale"])
        XCTAssertEqual(voices.filter { $0.presentation == .masculine }.map(\.id), ["arbor", "breeze", "cove", "ember", "spruce"])
        XCTAssertEqual(HarnessProvider.codex.defaultVoice(for: .feminine), "juniper")
        XCTAssertEqual(HarnessProvider.codex.defaultVoice(for: .masculine), "cove")
        XCTAssertNil(HarnessProvider.codex.defaultVoice(for: nil))
        XCTAssertEqual(HarnessProvider.claudeCode.voices, [])
        XCTAssertNil(HarnessProvider.claudeCode.defaultVoice(for: .feminine))
    }

    func testABotsVoiceIsSavedWithItAndUsedForItsCalls() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        XCTAssertTrue(f.store.updateAgent(f.a, name: f.a.displayName, harnessIdentifier: "codex", modelIdentifier: nil,
            reasoningEffort: nil, avatarSymbolName: nil, avatarColorIndex: 0, avatarImageData: nil,
            publicDescription: "", backstory: "", voice: .some("maple")))
        XCTAssertEqual(f.store.voice(for: f.a), "maple")
        let process = try f.runtime.start(f.a)
        f.store.startVoiceCall(in: f.directA, media: VoiceCallMediaFake())
        try await wait { process.voiceCallRequests.count == 1 }
        XCTAssertEqual(process.voiceCallRequests.first?.voice, "maple")
    }

    func testABotWithoutAVoiceGetsOneMatchingItsNameAndKeepsIt() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(["Ada": .feminine, "Grace": .masculine])
        let defaultForNew = await f.store.defaultVoice(forBotNamed: "Grace", harnessIdentifier: "codex")
        XCTAssertEqual(defaultForNew, "cove")
        let noVoices = await f.store.defaultVoice(forBotNamed: "Ada", harnessIdentifier: "claude-code")
        XCTAssertNil(noVoices)

        let process = try f.runtime.start(f.a)
        XCTAssertNil(f.store.voice(for: f.a))
        f.store.startVoiceCall(in: f.directA, media: VoiceCallMediaFake())
        try await wait { process.voiceCallRequests.count == 1 }
        XCTAssertEqual(process.voiceCallRequests.first?.voice, "juniper")
        XCTAssertEqual(f.store.voice(for: f.a), "juniper")

        f.store.voiceCalls.hangUp()
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        try f.repository.updateAgentVoice(f.a, voice: nil)
        f.store.startVoiceCall(in: f.directA, media: VoiceCallMediaFake())
        try await wait { process.voiceCallRequests.count == 2 }
        XCTAssertNil(process.voiceCallRequests.last?.voice ?? nil)
        XCTAssertNil(f.store.voice(for: f.a))
    }

    func testEveryHarnessVoiceShipsAPreview() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Support/VoicePreviews")
        for provider in HarnessProvider.allCases {
            for voice in provider.voices {
                let file = folder.appendingPathComponent(VoicePreview.fileName(provider: provider, voice: voice.id))
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
            }
        }
    }

    func testSpokenLinesSitAmongWhatWasSentDuringTheCall() {
        let conversationID = UUID(), start = Date(timeIntervalSince1970: 1_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        func message(_ seconds: Double, _ body: String, call: VoiceCallRecord? = nil) -> ChatMessage {
            var message = ChatMessage(conversationID: conversationID, author: .user, body: body, createdAt: at(seconds), delivery: .delivered)
            message.call = call
            return message
        }
        let before = message(-60, "Earlier")
        let agentID = UUID()
        let card = message(0, "Voice call", call: VoiceCallRecord(agentID: agentID, endedAt: at(9), lines: [
            .init(.person, "Can you look at the log?", at: at(1)),
            .init(.bot, "Send it over.", at: at(2)),
            .init(.bot, "Got it, the build failed on tests.", at: at(5)),
            .init(.person, "Untimed", at: nil),
            .init(.person, "Thanks!", at: at(8)),
        ]))
        let typed = message(3, "build.log")
        let reply = message(6, "Here is the failing test.")
        let layout = VoiceCallLayout.spokenLines(in: [before, card, typed, reply], live: nil)
        XCTAssertEqual(layout[before.id], nil)
        XCTAssertEqual(layout[card.id]?.lines.map(\.text), ["Can you look at the log?", "Send it over.", "Untimed"])
        XCTAssertEqual(layout[typed.id]?.lines.map(\.text), ["Got it, the build failed on tests."])
        XCTAssertEqual(layout[reply.id]?.lines.map(\.text), ["Thanks!"])
        XCTAssertEqual(layout[reply.id]?.agentID, agentID)
        XCTAssertEqual(layout[reply.id]?.isLive, false)

        // While the call runs its lines come from the call, not the saved card.
        let live = VoiceCallLayout.spokenLines(in: [card, typed], live: (card.id, [.init(.bot, "Live", at: at(4))]))
        XCTAssertEqual(live[typed.id]?.lines.map(\.text), ["Live"])
        XCTAssertEqual(live[typed.id]?.isLive, true)
        XCTAssertEqual(live[card.id], nil)
    }

    func testCallsToABotOnAHubGoThroughTheHubAndOthersToTheirRuntime() async throws {
        let hubBot = UUID(), localBot = UUID(), channel = VoiceCallChannelFake()
        var opened: [(UUID, VoiceCallRequest)] = []
        let router = VoiceCallRouter(local: runtime, isOnHub: { $0 == hubBot }, openHubCall: { agent, request in
            opened.append((agent, request))
            return channel
        })
        var events: [VoiceCallEvent] = []
        let request = VoiceCallRequest(offer: "offer-sdp", voice: nil, conversationID: UUID(), personName: "Alex")
        try router.startVoiceCall(agentID: hubBot, request) { events.append($0) }
        try await wait { opened.count == 1 }
        XCTAssertEqual(opened.first?.1.offer, "offer-sdp")
        XCTAssertTrue(runtime.requests.isEmpty)

        channel.push(.answer("answer-sdp"))
        channel.push(.started)
        channel.push(.line(LinkCallLine(speaker: .you, text: "Hi", at: date)))
        try await wait { events.count == 3 }
        XCTAssertEqual(events, [.answer("answer-sdp"), .started, .line(.init(.person, "Hi", at: date))])

        // The Hub hears typed messages from the conversation itself.
        router.sendToVoiceCall(agentID: hubBot, "typed")
        XCTAssertEqual(runtime.sent, [])
        router.endVoiceCall(agentID: hubBot)
        XCTAssertEqual(channel.cancelled, 1)
        XCTAssertEqual(runtime.ended, [])

        try router.startVoiceCall(agentID: localBot, request) { _ in }
        router.sendToVoiceCall(agentID: localBot, "typed")
        router.endVoiceCall(agentID: localBot)
        XCTAssertEqual(runtime.requests.map(\.agentID), [localBot])
        XCTAssertEqual(runtime.sent, ["typed"])
        XCTAssertEqual(runtime.ended, [localBot])
    }

    func testCallTimeKeepsOneWidthUntilAnHour() {
        XCTAssertEqual([0, 5, 65, 599, 3599, 3725].map { VoiceCallTimer.format(TimeInterval($0)) },
                       ["00:00", "00:05", "01:05", "09:59", "59:59", "1:02:05"])
    }

    func testWebKitCallsTheMicrophoneDecision() {
        // A completion-handler form can silently stop matching the selector, leaving WebKit to deny capture.
        XCTAssertTrue(WebRTCVoiceCallMedia().responds(
            to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
    }

    func testCallsAreOfferedForRunningDirectBotsAndCarryTheConversation() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        // The harness decides, not whether the bot happens to be running right now.
        XCTAssertEqual(f.store.voiceCallTarget(for: f.directA)?.id, f.a.id)
        XCTAssertNil(f.store.voiceCallTarget(for: try f.group()))
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)

        f.store.setDraft("Earlier question", for: f.directA.id)
        f.store.sendDraft(to: f.directA.id)
        let fake = VoiceCallMediaFake()
        f.store.startVoiceCall(in: f.directA, media: fake)
        try await wait { f.runtime.factory.processes.first?.voiceCallRequests.count == 1 }
        let process = try XCTUnwrap(f.runtime.factory.processes.first)
        let request = try XCTUnwrap(process.voiceCallRequests.first)
        XCTAssertNil(request.voice)
        XCTAssertEqual(request.conversationID, f.directA.id)
        XCTAssertEqual(request.recentLines.last, .init(.person, "Earlier question"))

        f.store.setDraft("Typed during the call", for: f.directA.id)
        f.store.sendDraft(to: f.directA.id)
        XCTAssertEqual(process.voiceCallTexts, [VoiceCallDocumentation.typedMessage(body: "Typed during the call", attachmentNames: [])])
        f.store.voiceCalls.hangUp()
        XCTAssertEqual(process.voiceCallEnds, 1)
    }

    func testTheCallShortcutCallsTheShownBotOrEndsTheCallInProgress() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        f.store.toggleVoiceCall(in: try f.group().id)
        f.store.toggleVoiceCall(in: nil)
        XCTAssertNil(f.store.voiceCalls.call)

        f.store.toggleVoiceCall(in: f.directA.id, media: VoiceCallMediaFake())
        try await wait { f.runtime.factory.processes.first?.voiceCallRequests.count == 1 }
        XCTAssertEqual(f.store.voiceCalls.call?.conversationID, f.directA.id)
        // Any window ends the one call there is, wherever it was started.
        f.store.toggleVoiceCall(in: nil)
        XCTAssertNil(f.store.voiceCalls.call)
        XCTAssertEqual(f.runtime.factory.processes.first?.voiceCallEnds, 1)
    }

    func testAConnectedCallIsLoggedInTheConversationWithItsTranscriptButNeverReachesTheBotsInbox() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let process = try f.runtime.start(f.a)
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        func callMessages() -> [ChatMessage] { f.store.messages(for: f.directA).filter { $0.call != nil } }

        // A call that never connects leaves nothing behind.
        f.store.startVoiceCall(in: f.directA, media: VoiceCallMediaFake())
        try await wait { process.voiceCallRequests.count == 1 }
        process.voiceCallEvents?(.ended("Invalid SDP offer."))
        XCTAssertEqual(callMessages(), [])

        f.store.startVoiceCall(in: f.directA, media: VoiceCallMediaFake())
        try await wait { process.voiceCallRequests.count == 2 }
        process.voiceCallEvents?(.started)
        let card = try XCTUnwrap(callMessages().first)
        XCTAssertEqual(callMessages().count, 1)
        XCTAssertEqual(card.call?.agentID, f.a.id)
        XCTAssertNil(card.call?.endedAt)
        XCTAssertEqual(f.store.voiceCalls.call?.messageID, card.id)

        process.voiceCallEvents?(.line(.init(.person, "Can you check the build?")))
        process.voiceCallEvents?(.line(.init(.bot, "It passed.")))
        f.store.setDraft("Typed during the call", for: f.directA.id)
        f.store.sendDraft(to: f.directA.id)
        XCTAssertEqual(try f.repository.latestMessages(for: f.a.id).map(\.message.body), ["Typed during the call"])

        f.store.voiceCalls.hangUp()
        let saved = try XCTUnwrap(try f.repository.loadMessages(conversationID: f.directA.id).first { $0.id == card.id })
        XCTAssertEqual(saved.call?.lines.map(\.text), ["Can you check the build?", "It passed."])
        XCTAssertEqual(saved.call?.lines.map(\.speaker), [.person, .bot])
        XCTAssertTrue(saved.call?.lines.allSatisfy { $0.at != nil } == true)
        let endedAt = try XCTUnwrap(saved.call?.endedAt)
        XCTAssertGreaterThanOrEqual(endedAt, saved.createdAt)
        XCTAssertEqual(callMessages().first?.call?.lines.map(\.text), saved.call?.lines.map(\.text))
        XCTAssertNotNil(callMessages().first?.call?.endedAt)
        XCTAssertEqual(try f.repository.latestMessages(for: f.a.id).count, 0)
    }
}
