import Foundation
@testable import HubCore
import HubLink
import HubMac
import NoodleCore
import NoodleRuntime
import XCTest

/// A bot's call ringing its owner's devices through Noodle Push, here a stand-in
/// that keeps what the Hub posted and answers as Push would. Devices pair over real QUIC on this Mac.
@MainActor final class CallPushTests: XCTestCase {
    /// Stands in for Noodle Push.
    private actor FakePush: CallPushTransport {
        private(set) var posts: [(url: URL, body: Data)] = []
        private var reply = (status: 200, body: Data(#"{"outcome":"sent","apnsStatus":200}"#.utf8))

        func post(_ body: Data, to url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
            posts.append((url, body))
            return reply
        }

        func answer(_ status: Int, _ json: String) { reply = (status, Data(json.utf8)) }

        var rings: [PushRingRequest] { posts.compactMap { try? JSONDecoder().decode(PushRingRequest.self, from: $0.body) } }
    }

    private struct Fixture {
        let hub: Hub
        /// Where the Hub keeps its files.
        let folder: URL
        let link: HubLinkService
        /// Ada's phone, which has Noodle closed, and her Mac, which follows the Hub.
        let phone: HubPairing
        let mac: HubPairing
        let kai: LinkBot
        let push: FakePush
        let logged: () -> [String]
    }

    private let callKey = Data(repeating: 5, count: 32)

    private func fixture() async throws -> Fixture {
        let (runtime, _) = try fakeRuntime()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-call-push-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let hub = Hub(root: root.appendingPathComponent("Hub"), messenger: nil, runtime: runtime)
        try hub.repository.prepare()
        let push = FakePush()
        var lines: [String] = []
        let link = HubLinkService(hubName: "Mac mini", directory: root.appendingPathComponent("Hub/Link"),
                                  access: hub.access, profiles: hub.harnessProfiles, bots: hub.bots,
                                  connections: hub.connections, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] },
                                  callPushes: push, callPushLog: { lines.append($0) })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        hub.bots.watch()
        let family = try hub.access.addPlan(named: "Family")
        hub.access.set(HubHarness(provider: .codex, profile: nil), included: true, in: family)
        let ada = try hub.access.addUser(named: "Ada")
        hub.access.move(ada, to: family)
        let phone = HubPairing(directory: root.appendingPathComponent("Phone"), deviceName: "iPhone")
        await phone.join(link.invite(ada).url().absoluteString)
        let mac = HubPairing(directory: root.appendingPathComponent("Mac"), deviceName: "Mac")
        await mac.join(link.invite(ada).url().absoluteString)
        XCTAssertNil(phone.error)
        XCTAssertNil(mac.error)
        guard case .bot(let kai) = try await mac.request(.createBot(LinkBotDraft(name: "Kai", provider: "codex"))) else {
            throw XCTSkip("no bot")
        }
        return Fixture(hub: hub, folder: root.appendingPathComponent("Hub"), link: link, phone: phone, mac: mac, kai: kai, push: push, logged: { lines })
    }

    /// The grant a device sends, for the Hub it paired with, from the token Push sealed for it.
    private func grant(_ device: HubPairing, days: Double = 14) throws -> LinkCallPush {
        LinkCallPush(grant: try device.callGrant(sealed: Data("sealed for \(device.directory.lastPathComponent)".utf8),
                                                 expiresAt: Date().addingTimeInterval(days * 86_400)), callKey: callKey)
    }

    private func status(_ device: HubPairing) async throws -> LinkStatus {
        guard case .status(let status) = try await device.request(.status) else { throw XCTSkip("no status") }
        return status
    }

    private func phoneGrant(_ f: Fixture) -> HubCallPush? {
        f.hub.access.devices.first { $0.name == "iPhone" }?.callPush
    }

    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<250 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A call rings every device with a grant through Push, with a request the Hub signed over the device's own
    /// grant and the caller only the device can read, even the phone that still follows the Hub: a locked phone
    /// looks connected until its connection times out, and its suspended app cannot ring in-app.
    func testACallRingsEveryDeviceWithAGrantThroughPushEvenWhileItFollowsTheHub() async throws {
        let f = try await fixture()
        let sent = try grant(f.phone)
        let answer = try await f.phone.request(.callPush(sent))
        XCTAssertEqual(answer, .done)
        let fromMac = try grant(f.mac)
        _ = try await f.mac.request(.callPush(fromMac))
        let status = try await status(f.phone)
        XCTAssertTrue(status.ringsThroughPush)
        XCTAssertEqual(status.callPushExpiresAt, sent.grant.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) })
        // Both follow the Hub, as a phone does for a while after it locks.
        let phoneEvents = try await f.phone.subscribe()
        let macEvents = try await f.mac.subscribe()
        _ = try await f.phone.request(.status)
        _ = try await f.mac.request(.status)

        let request = try f.hub.repository.requestCall(agentID: f.kai.id, reason: "The build is broken")
        let started = Int64(Date().timeIntervalSince1970)
        f.hub.bots.ringCall(of: f.kai.id)
        await until { await f.push.posts.count >= 2 }
        // Long enough for a third ring to have been posted, had there been one.
        try await Task.sleep(for: .milliseconds(300))

        let posts = await f.push.posts
        XCTAssertEqual(posts.map(\.url), Array(repeating: URL(string: "https://push.usenoodle.app/v1/ring")!, count: 2),
                       "Each device with a grant is rung once, following the Hub or not")
        let all = await f.push.rings
        XCTAssertEqual(Set(all.map(\.grant.deviceKey)), Set([try XCTUnwrap(sent.grant).deviceKey, try XCTUnwrap(fromMac.grant).deviceKey]))
        XCTAssertEqual(Set(all.map(\.callID)), [request.id], "One call ID, so the phone rings a push and an in-app ring once")
        let ring = try XCTUnwrap(all.first { $0.grant == sent.grant })
        XCTAssertTrue(ring.hasValidSignature, "Signed by the Hub the grant names, as Push checks")
        XCTAssertEqual(ring.grant, sent.grant)
        XCTAssertEqual(ring.grant.hubKey, f.link.key.x963)
        XCTAssertEqual(ring.callID, request.id, "The phone reports the call under the Hub's ID, so a push and an in-app ring are one call")
        XCTAssertTrue((40...45).contains(ring.secondsLeft))
        XCTAssertTrue((started - 5...started + 5).contains(ring.timestamp))
        let caller = try XCTUnwrap(LinkCallPushCaller.open(ring.blob, callID: request.id, with: callKey))
        XCTAssertEqual([caller.botID, caller.conversationID], [f.kai.id, f.kai.conversationID])
        XCTAssertEqual(caller.botName, "Kai")
        XCTAssertTrue((started + 40...started + 46).contains(caller.expiresAt ?? 0), "The Hub's own end of the ring, which Push cannot change")
        withExtendedLifetime((phoneEvents, macEvents)) {}
    }

    /// When Push says the token is gone, the Hub forgets the grant and tells the phone in its status, which
    /// registers again and sends a new one on its next connect. A busy Push leaves the grant alone.
    func testAGrantPushCannotRingWithIsForgottenAndTheDeviceSeesIt() async throws {
        let f = try await fixture()
        _ = try await f.phone.request(.callPush(try grant(f.phone)))
        XCTAssertNotNil(phoneGrant(f))

        await f.push.answer(429, #"{"outcome":"rateLimited","reason":"deviceLimit"}"#)
        _ = try f.hub.repository.requestCall(agentID: f.kai.id, reason: "The disk is full")
        f.hub.bots.ringCall(of: f.kai.id)
        await until { await !f.push.posts.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(phoneGrant(f), "Rate limited: the next call tries again")

        await f.push.answer(410, #"{"outcome":"unregistered","apnsStatus":410,"reason":"Unregistered"}"#)
        let later = Date().addingTimeInterval(AgentCallLimits.cooldown + 60)
        _ = try f.hub.repository.requestCall(agentID: f.kai.id, reason: "The disk is still full", now: later)
        f.hub.bots.ringCall(of: f.kai.id, now: later)
        await until { self.phoneGrant(f) == nil }
        XCTAssertNil(phoneGrant(f))
        let status = try await status(f.phone)
        XCTAssertNil(status.callPushExpiresAt)
        let count = await f.push.posts.count
        XCTAssertEqual(count, 2)
    }

    /// Which of Push's answers mean the grant can never ring again.
    func testOnlyAnswersThatCanNeverRingAgainDropTheGrant() {
        func drops(_ outcome: PushRingResult.Outcome, _ reason: String? = nil) -> Bool {
            CallPusher.dropsGrant(PushRingResult(outcome: outcome, reason: reason))
        }
        XCTAssertTrue(drops(.unregistered, "BadDeviceToken"))
        XCTAssertTrue(drops(.registrationExpired))
        XCTAssertTrue(drops(.grantExpired))
        for reason in ["badSealedToken", "badGrant", "grantTooLong"] { XCTAssertTrue(drops(.rejected, reason), reason) }
        XCTAssertFalse(drops(.rejected, "badSignature"), "Logged, not dropped: the grant may be fine")
        XCTAssertFalse(drops(.rejected, "staleRequest"), "The Hub's clock, which a new grant would not mend")
        for kept in [PushRingResult.Outcome.sent, .duplicate, .rateLimited, .failed] { XCTAssertFalse(drops(kept), kept.rawValue) }
        XCTAssertFalse(CallPusher.dropsGrant(nil), "No answer")
    }

    /// After Push says the Hub as a whole sends too many, from its address or its key, the Hub sends no ring
    /// for a minute; a limit on one device does not pause the others.
    func testRingsPauseForAMinuteWhenPushLimitsTheHub() async throws {
        let push = FakePush()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let pusher = CallPusher(key: LinkIdentity().privateKey, transport: push, now: { clock }, log: { _ in })
        let phone = LinkIdentity(), hub = LinkIdentity()
        let grant = HubCallPush(grant: try CallGrant.signed(sealed: Data([1]), hubKey: hub.publicKey.x963,
                                                            expiresAt: Int64(clock.timeIntervalSince1970) + 86_400, by: phone.privateKey),
                                callKey: callKey)
        let call = LinkIncomingCall(id: UUID(), botID: UUID(), conversationID: UUID(), reason: "", secondsLeft: 40)

        await push.answer(429, #"{"outcome":"rateLimited","reason":"deviceLimit"}"#)
        _ = await pusher.ring(call, botName: "Kai", with: grant)
        _ = await pusher.ring(call, botName: "Kai", with: grant)
        var count = await push.posts.count
        XCTAssertEqual(count, 2, "One device's limit leaves the rest ringing")

        await push.answer(429, #"{"outcome":"rateLimited","reason":"hubLimit"}"#)
        _ = await pusher.ring(call, botName: "Kai", with: grant)
        let paused = await pusher.ring(call, botName: "Kai", with: grant)
        count = await push.posts.count
        XCTAssertEqual(count, 3)
        XCTAssertNil(paused)
        clock = clock.addingTimeInterval(61)
        _ = await pusher.ring(call, botName: "Kai", with: grant)
        count = await push.posts.count
        XCTAssertEqual(count, 4)
    }

    /// The Hub's file of devices holds their grants and call keys now, so only the Hub's user may read it.
    func testTheFileWithGrantsIsReadableOnlyByTheHub() async throws {
        let f = try await fixture()
        _ = try await f.phone.request(.callPush(try grant(f.phone)))
        let file = f.folder.appendingPathComponent("access.json")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    /// The Hub keeps only a current grant its device signed for this Hub, and forgets it when the device stops.
    func testAHubKeepsOnlyAGrantItsDeviceSignedForIt() async throws {
        let f = try await fixture()
        let other = LinkIdentity()
        let forAnother = LinkCallPush(grant: try CallGrant.signed(sealed: Data([1]), hubKey: other.publicKey.x963,
                                                                  expiresAt: Int64(Date().timeIntervalSince1970) + 86_400,
                                                                  by: other.privateKey), callKey: callKey)
        do {
            _ = try await f.phone.request(.callPush(forAnother))
            XCTFail("Kept a grant for another Hub")
        } catch {}
        do {
            _ = try await f.phone.request(.callPush(try grant(f.mac)))
            XCTFail("Kept the Mac's grant from the phone")
        } catch {}
        XCTAssertNil(phoneGrant(f))

        _ = try await f.phone.request(.callPush(try grant(f.phone)))
        XCTAssertNotNil(phoneGrant(f))
        _ = try await f.phone.request(.callPush(LinkCallPush(grant: nil, callKey: nil)))
        XCTAssertNil(phoneGrant(f))
        let status = try await status(f.phone)
        XCTAssertNil(status.callPushExpiresAt)
    }

    /// What the Hub logs of a ring says what Push answered, never the grant, the keys or who called.
    func testRingsAreLoggedWithoutGrantsKeysOrCallers() async throws {
        let f = try await fixture()
        let push = try grant(f.phone)
        _ = try await f.phone.request(.callPush(push))
        await f.push.answer(410, #"{"outcome":"unregistered","apnsStatus":410,"reason":"Unregistered"}"#)
        _ = try f.hub.repository.requestCall(agentID: f.kai.id, reason: "The build is broken")
        f.hub.bots.ringCall(of: f.kai.id)
        await until { f.logged().contains { $0.contains("unregistered") } }
        let log = f.logged().joined(separator: "\n")
        XCTAssertTrue(log.contains("unregistered"), log)
        XCTAssertTrue(log.contains("410"), log)
        let rings = await f.push.rings
        let ring = try XCTUnwrap(rings.first)
        let grant = try XCTUnwrap(push.grant)
        let secrets = [grant.sealed, grant.signature, grant.deviceKey, callKey, ring.blob, ring.signature]
            .flatMap { [$0.base64EncodedString(), $0.map { String(format: "%02x", $0) }.joined()] }
        for secret in secrets { XCTAssertFalse(log.contains(secret), "Logged a secret") }
        for word in ["Kai", "sealed", "broken", f.kai.id.uuidString] { XCTAssertFalse(log.contains(word), word) }
    }
}
