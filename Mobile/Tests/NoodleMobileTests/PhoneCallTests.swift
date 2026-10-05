import Foundation
import HubLink
@testable import NoodleMobile
import Testing

@MainActor final class CallChannelFake: CallChannel {
    let frames: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var cancelled = 0
    init() { (frames, continuation) = AsyncThrowingStream.makeStream() }
    func push(_ event: LinkCallEvent) { continuation.yield(event.encoded) }
    nonisolated func cancel() { MainActor.assumeIsolated { cancelled += 1; continuation.finish(throwing: CancellationError()) } }
}

@MainActor final class CallAudioFake: CallAudio {
    var onFailure: ((String) -> Void)?
    var offerError: Error?
    var answers: [String] = []
    var muted: [Bool] = []
    var chimes = 0
    var closed = 0
    func prepareOffer() async throws -> String {
        if let offerError { throw offerError }
        return "offer-sdp"
    }
    func accept(answer: String) async throws { answers.append(answer) }
    func setMuted(_ muted: Bool) { self.muted.append(muted) }
    func announceConnected() { chimes += 1 }
    func close() { closed += 1 }
}

private struct Failure: LocalizedError {
    let errorDescription: String?
}

@MainActor @Suite struct PhoneCallTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func aCallConnectsThroughTheHubAndEndsWhenEitherSideHangsUp() async throws {
        let channel = CallChannelFake(), audio = CallAudioFake()
        var opened: [LinkCallStart] = []
        let calls = PhoneCalls(open: { opened.append($0); return channel }, makeAudio: { audio }, now: { [date] in date })
        let thread = UUID(), conversation = UUID()
        calls.start(threadID: thread, conversationID: conversation)
        #expect(calls.call?.threadID == thread)
        #expect(calls.call?.startedAt == nil)
        await wait { opened.count == 1 }
        #expect(opened == [LinkCallStart(conversationID: conversation, offer: "offer-sdp")])

        channel.push(.answer("answer-sdp"))
        await wait { audio.answers == ["answer-sdp"] }
        #expect(audio.answers == ["answer-sdp"])
        channel.push(.started)
        channel.push(.line(LinkCallLine(speaker: .bot, text: "Hello", at: date)))
        await wait { calls.call?.lines.count == 1 }
        #expect(calls.call?.startedAt == date)
        #expect(audio.chimes == 1)
        #expect(calls.call?.lines.map(\.text) == ["Hello"])

        calls.toggleMute()
        #expect(calls.call?.isMuted == true)
        #expect(audio.muted == [true])

        calls.hangUp()
        #expect(calls.call == nil)
        #expect(channel.cancelled == 1)
        #expect(audio.closed == 1)
        #expect(calls.problem == nil)

        let ending = CallChannelFake(), endingAudio = CallAudioFake()
        let other = PhoneCalls(open: { _ in ending }, makeAudio: { endingAudio }, now: { [date] in date })
        other.start(threadID: thread, conversationID: conversation)
        await wait { endingAudio.answers.isEmpty && ending.cancelled == 0 && other.call != nil }
        ending.push(.ended("This bot cannot take calls."))
        await wait { other.call == nil }
        #expect(other.call == nil)
        #expect(other.problem == "This bot cannot take calls.")
        #expect(endingAudio.closed == 1)
    }

    @Test func aCallThatCannotUseTheMicrophoneNeverReachesTheHub() async throws {
        let audio = CallAudioFake()
        audio.offerError = Failure(errorDescription: "Microphone access is off.")
        var opened = 0
        let calls = PhoneCalls(open: { _ in opened += 1; return CallChannelFake() }, makeAudio: { audio }, now: { [date] in date })
        calls.start(threadID: UUID(), conversationID: UUID())
        await wait { calls.call == nil }
        #expect(calls.call == nil)
        #expect(opened == 0)
        #expect(calls.problem == "Microphone access is off.")
        #expect(audio.closed == 1)
    }

    @Test func whatWasSaidSitsAmongWhatWasSentDuringTheCall() {
        let conversation = UUID(), bot = UUID(), start = date
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        func message(_ seconds: Double, call: LinkCallRecord? = nil) -> LinkMessage {
            LinkMessage(id: UUID(), conversationID: conversation, author: .you, body: "", createdAt: at(seconds), delivered: true, call: call)
        }
        let card = message(0, call: LinkCallRecord(botID: bot, endedAt: at(9), lines: [
            LinkCallLine(speaker: .you, text: "Look at this", at: at(1)),
            LinkCallLine(speaker: .bot, text: "Got it", at: at(5)),
        ]))
        let typed = message(3)
        let blocks = CallLayout.blocks(in: [card, typed], live: nil)
        #expect(blocks[card.id]?.lines.map(\.text) == ["Look at this"])
        #expect(blocks[typed.id]?.lines.map(\.text) == ["Got it"])
        #expect(blocks[typed.id]?.botID == bot)

        let live = CallLayout.blocks(in: [card, typed], live: (card.id, [LinkCallLine(speaker: .bot, text: "Live", at: at(4))]))
        #expect(live[typed.id]?.lines.map(\.text) == ["Live"])
        #expect(live[typed.id]?.isLive == true)
    }
}
