import Foundation
import NoodleCore
import HubLink
import NoodleVoicePeer
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
    let playout = LinkCallPlayout(cushion: 1)
    var startError: Error?
    var hear: (@Sendable ([Int16]) -> Void)?
    var muted: [Bool] = []
    var closed = 0
    var connectedAnnouncements = 0
    func start(hear: @escaping @Sendable ([Int16]) -> Void) async throws {
        if let startError { throw startError }
        self.hear = hear
    }
    func setMuted(_ muted: Bool) { self.muted.append(muted) }
    func close() { closed += 1 }
    func announceConnected() { connectedAnnouncements += 1 }
    func played(_ count: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)
        playout.read(into: &out)
        return out
    }
}

/// Stands in for a call's WebRTC connection to the voice service.
final class VoiceCallPeerFake: VoiceCallPeering, @unchecked Sendable {
    var onVoice: (@Sendable ([Int16]) -> Void)?
    var onFailure: (@MainActor @Sendable () -> Void)?
    private let lock = NSLock()
    private var _heard: [Int16] = []
    private(set) var answers: [String] = []
    private(set) var closes = 0
    var heard: [Int16] { lock.withLock { _heard } }
    func makeOffer() async throws -> String { "peer-offer" }
    func accept(answer: String) async throws { answers.append(answer) }
    func hear(_ samples: [Int16]) { lock.withLock { _heard += samples } }
    func close() { closes += 1 }
}

@MainActor final class VoiceGuesserFake: VoicePresentationGuessing {
    let answers: [String: VoicePresentation]?
    init(_ answers: [String: VoicePresentation]?) { self.answers = answers }
    func presentation(forName name: String) async -> VoicePresentation? { answers?[name] }
}

final class VoiceCallChannelFake: VoiceCallChannel, @unchecked Sendable {
    let frames: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var _sent: [Data] = []
    private var _cancelled = 0
    var sent: [Data] { lock.withLock { _sent } }
    var cancelled: Int { lock.withLock { _cancelled } }
    init() { (frames, continuation) = AsyncThrowingStream.makeStream() }
    func push(_ event: LinkCallEvent) { continuation.yield(event.encoded) }
    func push(audio frame: Data) { continuation.yield(frame) }
    func send(_ payload: Data) { lock.withLock { _sent.append(payload) } }
    func cancel() { lock.withLock { _cancelled += 1 }; continuation.finish(throwing: CancellationError()) }
}

/// Starts of a call's audio, with voice processing or apart, failing with the given errors first.
private final class CallAudioStarts: @unchecked Sendable {
    private let lock = NSLock()
    private var processedFailures: [Error], apartFailures: [Error]
    private var processedCount = 0, apartCount = 0
    var counts: [Int] { lock.withLock { [processedCount, apartCount] } }

    init(processed: [Error], apart: [Error]) {
        processedFailures = processed
        apartFailures = apart
    }

    func processed() throws -> String {
        try lock.withLock {
            processedCount += 1
            if !processedFailures.isEmpty { throw processedFailures.removeFirst() }
            return "processed"
        }
    }

    func apart() throws -> String {
        try lock.withLock {
            apartCount += 1
            if !apartFailures.isEmpty { throw apartFailures.removeFirst() }
            return "apart"
        }
    }
}

private struct FixtureError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor final class VoiceCallTests: XCTestCase {
    private var runtime = VoiceCallRuntimeFake()
    private var media: [VoiceCallMediaFake] = []
    private var peers: [VoiceCallPeerFake] = []
    private var reports: [String] = []
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func router() -> VoiceCallRouter {
        VoiceCallRouter(local: runtime, isOnHub: { _ in false }, openHubCall: { _, _ in VoiceCallChannelFake() },
                        makePeer: { [unowned self] in let next = VoiceCallPeerFake(); peers.append(next); return next })
    }

    private func controller() -> VoiceCallController {
        VoiceCallController(router: router(), makeMedia: { [unowned self] in
            let next = VoiceCallMediaFake(); media.append(next); return next
        }, report: { [unowned self] in reports.append($0) }, now: { [date] in date })
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate())
    }

    /// A bot on this Mac: the call's own WebRTC connection makes the offer and takes the answer,
    /// the microphone's audio goes to it and its voice to the speakers.
    func testCallConnectsThroughMediaAndRuntimeAndShowsSpokenLines() async throws {
        let calls = controller(), agentID = UUID(), conversationID = UUID()
        calls.start(agentID: agentID, conversationID: conversationID, voice: "cove", personName: "Alex",
                    recentLines: [.init(.person, "Hello")])
        XCTAssertEqual(calls.call?.conversationID, conversationID)
        XCTAssertNil(calls.call?.startedAt)
        try await wait { runtime.requests.count == 1 }
        let request = try XCTUnwrap(runtime.requests.first)
        XCTAssertEqual(request.agentID, agentID)
        XCTAssertEqual(request.request.offer, "peer-offer")
        XCTAssertEqual(request.request.voice, "cove")
        XCTAssertEqual(request.request.conversationID, conversationID)
        XCTAssertEqual(request.request.personName, "Alex")
        XCTAssertEqual(request.request.recentLines, [.init(.person, "Hello")])

        runtime.events?(.answer("answer-sdp"))
        try await wait { peers.first?.answers == ["answer-sdp"] }
        XCTAssertEqual(media.first?.connectedAnnouncements, 0)
        try await wait { media.first?.hear != nil }
        media.first?.hear?([1, 2, 3])
        try await wait { peers.first?.heard == [1, 2, 3] }
        XCTAssertEqual(peers.first?.heard, [1, 2, 3])
        peers.first?.onVoice?([5, 6])
        XCTAssertEqual(media.first?.played(2), [5, 6])
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
        XCTAssertEqual(peers.first?.closes, 1)
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
        let calls = VoiceCallController(router: router(), makeMedia: { [unowned self] in
            let next = VoiceCallMediaFake(); next.startError = FixtureError("Microphone access is off."); media.append(next); return next
        }, report: { [unowned self] in reports.append($0) }, now: { [date] in date })
        calls.start(agentID: UUID(), conversationID: UUID(), voice: "cove", personName: "Alex", recentLines: [])
        try await wait { calls.call == nil }
        XCTAssertEqual(runtime.requests.count, 0)
        XCTAssertEqual(reports, ["Microphone access is off."])
        XCTAssertEqual(media.first?.closed, 1)
    }

    /// Refusing voice processing can switch a Bluetooth headset into its call mode, and starting
    /// apart fails until that settles: it is tried again instead of ending the call.
    func testCallAudioStartsApartAgainWhileAHeadsetSettles() async throws {
        let starts = CallAudioStarts(processed: [Self.formatNotSupported], apart: [Self.formatNotSupported])
        var waits = 0
        let started = try await VoiceCallAudioStart.run(audio: VoiceAudioQueue(), processed: { try starts.processed() },
                                                        apart: { try starts.apart() }, wait: { waits += 1 })
        XCTAssertEqual(started, "apart")
        XCTAssertEqual(starts.counts, [1, 2])
        XCTAssertEqual(waits, 1)
    }

    func testCallAudioUsesVoiceProcessingWhenItStarts() async throws {
        let starts = CallAudioStarts(processed: [], apart: [])
        var waits = 0
        let started = try await VoiceCallAudioStart.run(audio: VoiceAudioQueue(), processed: { try starts.processed() },
                                                        apart: { try starts.apart() }, wait: { waits += 1 })
        XCTAssertEqual(started, "processed")
        XCTAssertEqual(starts.counts, [1, 0])
        XCTAssertEqual(waits, 0)
    }

    /// Core Audio's own error never reaches the person; a microphone's message, which says what to do, does.
    func testCallAudioThatNeverStartsIsReportedReadably() async throws {
        let failures = Array(repeating: Self.formatNotSupported as Error, count: VoiceCallAudioStart.attempts)
        let starts = CallAudioStarts(processed: [Self.formatNotSupported], apart: failures)
        var waits = 0
        do {
            _ = try await VoiceCallAudioStart.run(audio: VoiceAudioQueue(), processed: { try starts.processed() },
                                                  apart: { try starts.apart() }, wait: { waits += 1 })
            XCTFail("Call audio started")
        } catch {
            XCTAssertTrue(error is VoiceCallAudioStart.StartFailure)
            XCTAssertFalse(error.localizedDescription.contains("10868"))
        }
        XCTAssertEqual(starts.counts, [1, VoiceCallAudioStart.attempts])
        XCTAssertEqual(waits, VoiceCallAudioStart.attempts - 1)

        let disconnected = VoiceFailure("The selected microphone is disconnected. Choose another in Settings → Conversation.")
        let unplugged = CallAudioStarts(processed: [disconnected],
                                        apart: Array(repeating: disconnected, count: VoiceCallAudioStart.attempts))
        do {
            _ = try await VoiceCallAudioStart.run(audio: VoiceAudioQueue(), processed: { try unplugged.processed() },
                                                  apart: { try unplugged.apart() }, wait: {})
            XCTFail("Call audio started")
        } catch {
            XCTAssertEqual(error.localizedDescription, disconnected.message)
        }
    }

    private static let formatNotSupported = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)

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
        f.store.makeCallPeer = { VoiceCallPeerFake() }
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
        f.store.makeCallPeer = { VoiceCallPeerFake() }
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

    /// A bot on a Hub is called through it: the Hub holds the voice connection, and the audio
    /// goes over the link both ways. A bot here gets its own connection.
    func testCallsToABotOnAHubGoThroughTheHubAndOthersToTheirRuntime() async throws {
        let hubBot = UUID(), localBot = UUID(), channel = VoiceCallChannelFake()
        var opened: [(UUID, VoiceCallSetup)] = []
        let router = VoiceCallRouter(local: runtime, isOnHub: { $0 == hubBot }, openHubCall: { agent, setup in
            opened.append((agent, setup))
            return channel
        }, makePeer: { [unowned self] in let next = VoiceCallPeerFake(); peers.append(next); return next })
        var events: [VoiceCallEvent] = []
        let setup = VoiceCallSetup(voice: nil, conversationID: UUID(), personName: "Alex")
        let playout = LinkCallPlayout(cushion: 1)
        let send = try await router.startVoiceCall(agentID: hubBot, setup, playout: playout) { events.append($0) }
        XCTAssertEqual(opened.first?.1, setup)
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertTrue(peers.isEmpty, "The Hub holds the connection")

        channel.push(.started)
        channel.push(.line(LinkCallLine(speaker: .you, text: "Hi", at: date)))
        let tone = (0..<960).map { Int16(sin(Double($0) * 2 * .pi * 440 / 48_000) * 8000) }
        let encoder = try LinkCallEncoder()
        for packet in try encoder.encode(tone + tone + tone) { channel.push(audio: LinkCallAudio.frame(packet)) }
        try await wait { events.count == 2 }
        XCTAssertEqual(events, [.started, .line(.init(.person, "Hi", at: date))])
        var played = [Int16](repeating: 0, count: 960)
        for _ in 0..<200 {
            playout.read(into: &played)
            if played.contains(where: { $0 != 0 }) { break }
            await Task.yield()
        }
        XCTAssertTrue(played.contains { abs(Int($0)) > 1000 }, "The bot's voice reaches the speakers")

        send(tone + tone)
        XCTAssertFalse(channel.sent.isEmpty)
        XCTAssertTrue(channel.sent.allSatisfy { LinkCallAudio.packet(in: $0) != nil }, "The person's voice goes up as audio frames")

        // The Hub hears typed messages from the conversation itself.
        router.sendToVoiceCall(agentID: hubBot, "typed")
        XCTAssertEqual(runtime.sent, [])
        router.endVoiceCall(agentID: hubBot)
        XCTAssertEqual(channel.cancelled, 1)
        XCTAssertEqual(runtime.ended, [])

        _ = try await router.startVoiceCall(agentID: localBot, setup, playout: playout) { _ in }
        XCTAssertEqual(runtime.requests.map(\.request.offer), ["peer-offer"])
        router.sendToVoiceCall(agentID: localBot, "typed")
        router.endVoiceCall(agentID: localBot)
        XCTAssertEqual(runtime.requests.map(\.agentID), [localBot])
        XCTAssertEqual(runtime.sent, ["typed"])
        XCTAssertEqual(runtime.ended, [localBot])
        XCTAssertEqual(peers.first?.closes, 1)
    }

    func testCallTimeKeepsOneWidthUntilAnHour() {
        XCTAssertEqual([0, 5, 65, 599, 3599, 3725].map { VoiceCallTimer.format(TimeInterval($0)) },
                       ["00:00", "00:05", "01:05", "09:59", "59:59", "1:02:05"])
    }

    func testCallsAreOfferedForRunningDirectBotsAndCarryTheConversation() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        // The harness decides, not whether the bot happens to be running right now.
        XCTAssertEqual(f.store.voiceCallTarget(for: f.directA)?.id, f.a.id)
        XCTAssertNil(f.store.voiceCallTarget(for: try f.group()))
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)

        f.store.makeCallPeer = { VoiceCallPeerFake() }
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
        // Sent from a Shortcut, as Pion's do, it reaches the call too.
        _ = try f.store.sendCommand("From a Shortcut", to: f.directA.id)
        XCTAssertEqual(process.voiceCallTexts.last, VoiceCallDocumentation.typedMessage(body: "From a Shortcut", attachmentNames: []))
        f.store.voiceCalls.hangUp()
        XCTAssertEqual(process.voiceCallEnds, 1)
    }

    func testTheCallShortcutCallsTheShownBotOrEndsTheCallInProgress() async throws {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        f.store.makeCallPeer = { VoiceCallPeerFake() }
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
        f.store.makeCallPeer = { VoiceCallPeerFake() }
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
