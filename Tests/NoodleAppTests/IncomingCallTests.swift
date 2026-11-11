import Foundation
import HubCore
import HubLink
import HubMac
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class IncomingCallTests: XCTestCase {
    private let date = Date()

    private func wait(_ what: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), what)
    }

    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        f.store.makeCallPeer = { VoiceCallPeerFake() }
        return f
    }

    /// What Noodle left the bot to read on its next wake.
    private func wakeNotes(_ f: StoreFixture, _ agent: AgentRecord) -> String {
        let file = f.repository.storage(for: agent.id).package.appendingPathComponent("wakes.json")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    private func cards(_ f: StoreFixture) -> [VoiceCallRecord] {
        f.store.messages(for: f.directA).compactMap(\.call)
    }

    func testABotsCallRingsAndAnsweringCallsItToldWhyItCalled() async throws {
        let f = try fixture()
        // Noodle rings a bot's call as soon as Messenger accepts it.
        XCTAssertNotNil(f.store.messenger.onCallRequested)
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The release build is failing", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        f.store.ringCall(of: f.a.id, now: date)
        XCTAssertEqual(f.store.ringingCalls, [request])
        XCTAssertTrue(f.runtime.factory.processes.isEmpty, "Nothing connects to the bot before the call is answered")

        f.store.answerCall(request.id, media: VoiceCallMediaFake())
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        try await wait("the bot's voice was called") { f.runtime.factory.processes.first?.voiceCallRequests.count == 1 }
        XCTAssertEqual(f.store.voiceCalls.call?.conversationID, f.directA.id)
        XCTAssertEqual(f.runtime.factory.processes.first?.voiceCallRequests.first?.answeredCallReason, "The release build is failing")
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        XCTAssertTrue(cards(f).allSatisfy { $0.unanswered == nil })
        f.store.voiceCalls.hangUp()
    }

    func testADeclinedCallLeavesAnUnreadCardAndTellsTheBot() async throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "Need a decision on the release", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        f.store.declineCall(request.id)
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertNil(f.store.voiceCalls.call)
        XCTAssertEqual(cards(f).last?.unanswered, .declined)
        XCTAssertEqual(cards(f).last?.reason, "Need a decision on the release")
        XCTAssertTrue(f.store.unreadConversationIDs.contains(f.directA.id))
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        await f.runtime.runtime.settleWakes()
        XCTAssertTrue(wakeNotes(f, f.a).contains("declined your call about: Need a decision on the release"))
        // Answering once it is over does nothing.
        f.store.answerCall(request.id, media: VoiceCallMediaFake())
        XCTAssertNil(f.store.voiceCalls.call)
    }

    func testACallNobodyAnswersIsMissedOnce() async throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The disk is almost full", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        f.store.expireCalls(at: request.expiresAt.addingTimeInterval(-1))
        XCTAssertEqual(f.store.ringingCalls, [request])
        f.store.expireCalls(at: request.expiresAt)
        f.store.expireCalls(at: request.expiresAt.addingTimeInterval(1))
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertEqual(cards(f).map(\.unanswered), [.missed])
        await f.runtime.runtime.settleWakes()
        XCTAssertTrue(wakeNotes(f, f.a).contains("did not answer your call about: The disk is almost full"))
    }

    /// A call that rang while Noodle quit is missed when it is found too late.
    func testACallFoundAfterItExpiredIsMissedWithoutRinging() throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The disk is almost full", now: date)
        f.store.ringCall(of: f.a.id, now: request.expiresAt.addingTimeInterval(60))
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertEqual(cards(f).map(\.unanswered), [.missed])
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
    }

    /// Nobody on a call is rung: the call is left as missed. Answering never hangs up a call in progress.
    func testNoCallRingsDuringACallAndAnsweringNeverEndsOne() async throws {
        let f = try fixture()
        f.store.startVoiceCall(in: f.directB, media: VoiceCallMediaFake())
        try await wait("the call with Grace started") { f.store.voiceCalls.call != nil }
        _ = try f.repository.requestCall(agentID: f.a.id, reason: "The build is broken", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertEqual(cards(f).map(\.unanswered), [.missed])
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        f.store.voiceCalls.hangUp()

        let later = date.addingTimeInterval(AgentCallLimits.cooldown + 60)
        let ringing = try f.repository.requestCall(agentID: f.a.id, reason: "Still broken", now: later)
        f.store.ringCall(of: f.a.id, now: later)
        XCTAssertEqual(f.store.ringingCalls, [ringing])
        f.store.startVoiceCall(in: f.directB, media: VoiceCallMediaFake())
        try await wait("the call with Grace started") { f.store.voiceCalls.call != nil }
        f.store.answerCall(ringing.id, media: VoiceCallMediaFake())
        XCTAssertEqual(f.store.voiceCalls.call?.conversationID, f.directB.id)
        XCTAssertEqual(f.store.ringingCalls, [ringing], "It rings on until it is missed")
        f.store.voiceCalls.hangUp()
    }

    /// A bot archived while its call rings has nobody left to answer it: the call ends without a card or a note.
    func testACallOfABotArchivedWhileRingingEndsQuietly() async throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The build is broken", now: date)
        f.store.ringCall(of: f.a.id, now: date)
        XCTAssertEqual(f.store.ringingCalls, [request])
        XCTAssertTrue(f.store.setArchived(true, agentID: f.a.id))
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertNil(f.repository.pendingCall(agentID: f.a.id))
        f.store.expireCalls(at: request.expiresAt)
        await f.runtime.runtime.settleWakes()
        XCTAssertTrue(try f.repository.loadMessages(conversationID: f.directA.id).allSatisfy { $0.call == nil })
        XCTAssertFalse(wakeNotes(f, f.a).contains("your call"))
    }
}

/// A call from a bot on this Mac also rings the owner's phone joined to this Mac as a Hub. Whichever
/// answers, declines or lets it ring out stops the other, and the conversation gets one card at most;
/// over real QUIC on this Mac.
@MainActor final class ThisMacCallTests: XCTestCase {
    private let date = Date()

    private struct Joined {
        let f: StoreFixture
        let personal: PersonalHub
        let phone: HubPairing
        let events: AsyncThrowingStream<LinkEvent, Error>
    }

    /// This Mac as a Hub, with the owner's phone joined to it and following it.
    private func joined(_ f: StoreFixture) async throws -> Joined {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-this-mac-calls-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        f.store.thisMac.placement = .init(directory: root.appendingPathComponent("This Mac"), port: 0, router: nil,
                                          localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await f.store.thisMac.setOn(true)
        addTeardownBlock { await f.store.thisMac.setOn(false) }
        let personal = try XCTUnwrap(f.store.thisMac.hub)
        guard case .listening = personal.link.state else { throw XCTSkip("Could not listen: \(personal.link.state)") }
        personal.bots.voiceGuesser = VoiceGuesserFake(nil)
        personal.bots.makeCallPeer = { VoiceCallPeerFake() }
        let phone = HubPairing(directory: root.appendingPathComponent("Phone"), deviceName: "iPhone")
        await phone.join(personal.link.invite(personal.owner).url().absoluteString)
        XCTAssertNil(phone.error)
        let events = try await phone.subscribe()
        _ = try await phone.request(.status)
        return Joined(f: f, personal: personal, phone: phone, events: events)
    }

    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        f.store.voiceGuesser = VoiceGuesserFake(nil)
        f.store.makeCallPeer = { VoiceCallPeerFake() }
        return f
    }

    private func cards(_ f: StoreFixture) -> [VoiceCallRecord] {
        ((try? f.repository.loadMessages(conversationID: f.directA.id)) ?? []).compactMap(\.call)
    }

    private func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () -> Bool) async throws {
        for _ in 0..<1000 where !predicate() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), what, file: file, line: line)
    }

    private func expect(_ what: String, in events: AsyncThrowingStream<LinkEvent, Error>, file: StaticString = #filePath,
                        line: UInt = #line, where matches: @escaping @Sendable (LinkEvent) -> Bool) async throws {
        let heard = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for try await event in events where matches(event) { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !heard { XCTFail("Never heard \(what)", file: file, line: line) }
    }

    private func rang(_ request: AgentCallRequest) -> @Sendable (LinkEvent) -> Bool {
        let id = request.id, bot = request.agentID, conversation = request.conversationID
        return {
            guard case .callRinging(let call) = $0 else { return false }
            return call.id == id && call.botID == bot && call.conversationID == conversation
        }
    }

    func testABotsCallRingsThePhoneAndAnsweringOnTheMacStopsIt() async throws {
        let j = try await joined(try fixture())
        let request = try j.f.repository.requestCall(agentID: j.f.a.id, reason: "The release build is failing")
        j.f.store.ringCall(of: j.f.a.id)
        try await expect("the call ringing on the phone", in: j.events, where: rang(request))
        XCTAssertEqual(j.f.store.ringingCalls, [request], "It rings once on this Mac")

        j.f.store.answerCall(request.id, media: VoiceCallMediaFake())
        let id = request.id
        try await expect("the call stopping on the phone", in: j.events) { $0 == .callStopped(id: id) }
        XCTAssertTrue(j.personal.bots.ringingCalls(for: j.personal.owner.id).isEmpty)
        XCTAssertEqual(j.f.store.voiceCalls.call?.conversationID, j.f.directA.id)
        XCTAssertTrue(cards(j.f).allSatisfy { $0.unanswered == nil })
        j.f.store.voiceCalls.hangUp()
    }

    func testAnsweringOnThePhoneStopsTheMacRingingAndCallsTheBot() async throws {
        let j = try await joined(try fixture())
        let request = try j.f.repository.requestCall(agentID: j.f.a.id, reason: "The release build is failing")
        j.f.store.ringCall(of: j.f.a.id)
        try await expect("the call ringing on the phone", in: j.events, where: rang(request))

        let channel = try await j.phone.channel(.startCall(LinkCallStart(conversationID: j.f.directA.id, answering: request.id)))
        try await waitUntil("the Mac stopped ringing") { j.f.store.ringingCalls.isEmpty }
        try await waitUntil("the bot's voice was called") {
            j.f.runtime.factory.processes.contains { $0.voiceCallRequests.first?.answeredCallReason == "The release build is failing" }
        }
        XCTAssertNil(j.f.repository.pendingCall(agentID: j.f.a.id))
        XCTAssertNil(j.f.store.voiceCalls.call, "The call is the phone's, not this Mac's")
        XCTAssertTrue(cards(j.f).allSatisfy { $0.unanswered == nil })
        channel.cancel()
    }

    func testDecliningOnThePhoneStopsTheMacRingingWithOneCard() async throws {
        let j = try await joined(try fixture())
        let request = try j.f.repository.requestCall(agentID: j.f.a.id, reason: "Need a decision on the release")
        j.f.store.ringCall(of: j.f.a.id)
        try await expect("the call ringing on the phone", in: j.events, where: rang(request))

        _ = try await j.phone.request(.declineCall(id: request.id))
        try await waitUntil("the Mac stopped ringing") { j.f.store.ringingCalls.isEmpty }
        j.f.store.expireCalls(at: request.expiresAt)
        j.personal.bots.expireCalls(at: request.expiresAt)
        XCTAssertEqual(cards(j.f).map(\.unanswered), [.declined])
        XCTAssertNil(j.f.repository.pendingCall(agentID: j.f.a.id))
    }

    /// A call ringing when This Mac is switched on rings the phone too. Nobody answering leaves one missed card.
    func testACallRingingWhenSwitchedOnRingsThePhoneAndIsMissedOnce() async throws {
        let f = try fixture()
        let request = try f.repository.requestCall(agentID: f.a.id, reason: "The disk is almost full")
        f.store.ringCall(of: f.a.id)
        let j = try await joined(f)
        try await expect("the call ringing on the phone", in: j.events, where: rang(request))

        f.store.expireCalls(at: request.expiresAt)
        let id = request.id
        try await expect("the call stopping on the phone", in: j.events) { $0 == .callStopped(id: id) }
        j.personal.bots.expireCalls(at: request.expiresAt)
        XCTAssertTrue(f.store.ringingCalls.isEmpty)
        XCTAssertEqual(cards(f).map(\.unanswered), [.missed])
    }
}
