import CryptoKit
import Foundation
import HubWire
import os

/// Where the Hub posts its rings: Noodle Push, or a stand-in in tests.
public protocol CallPushTransport: Sendable {
    /// The HTTP status and body Push answered with. Throws when no answer came within `timeout`.
    func post(_ body: Data, to url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data)
}

/// Noodle Push over HTTPS, without cookies, caches or credentials.
public struct NoodlePushTransport: CallPushTransport {
    private static let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func post(_ body: Data, to url: URL, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await Self.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Rings a device that is away from the Hub, or has Noodle closed, through Noodle Push: one signed request
/// per device, carrying the grant the device gave and who is calling, encrypted with the device's key.
/// Push wakes the phone with a VoIP push and it rings on the phone's call screen.
///
/// A ring is tried once, as it rings in-app on the devices that follow the Hub either way, and a late
/// ring is worse than none. Logs say what Push answered, never the grant, keys, token or caller.
@MainActor final class CallPusher {
    /// How long a ring waits for Push, which itself waits up to 8 s for Apple.
    static let timeout: TimeInterval = 10

    private let key: P256.Signing.PrivateKey
    private let transport: any CallPushTransport
    private let service: URL
    private let now: () -> Date
    let log: (String) -> Void
    /// While Push limits this Hub as a whole, by its address or its key, no ring is sent until then.
    private var pausedUntil: Date?

    /// How long rings pause after Push said this Hub, or its address, sends too many.
    static let rateLimitPause: TimeInterval = 60

    init(key: P256.Signing.PrivateKey, transport: any CallPushTransport, service: URL = LinkCallPush.service,
         now: @escaping () -> Date = Date.init, log: ((String) -> Void)? = nil) {
        self.key = key
        self.transport = transport
        self.service = service
        self.now = now
        self.log = log ?? { Self.logger.notice("\($0, privacy: .public)") }
    }

    /// What Push made of the ring, or nil when it did not answer or the ring was not sent.
    func ring(_ call: LinkIncomingCall, botName: String, with push: HubCallPush) async -> PushRingResult? {
        if let pausedUntil, pausedUntil > now() {
            log("Did not ring a device away through Noodle Push: rate limited for a minute")
            return nil
        }
        let result: PushRingResult?
        do {
            // The Hub's own end of the ring travels with the caller too, so the phone stops ringing then
            // even if Push's copy were changed.
            let expiresAt = Int64(now().addingTimeInterval(call.secondsLeft).timeIntervalSince1970)
            let caller = LinkCallPushCaller(botID: call.botID, botName: botName, conversationID: call.conversationID, expiresAt: expiresAt)
            let request = try PushRingRequest.signed(
                grant: push.grant, callID: call.id, secondsLeft: min(300, max(1, Int(call.secondsLeft.rounded(.down)))),
                timestamp: Int64(now().timeIntervalSince1970), blob: try caller.sealed(callID: call.id, with: push.callKey), by: key)
            let answer = try await transport.post(try JSONEncoder().encode(request), to: service.appendingPathComponent("v1/ring"),
                                                  timeout: Self.timeout)
            result = (try? JSONDecoder().decode(PushRingResult.self, from: answer.body)) ?? Self.result(forStatus: answer.status)
            log("Rang a device away through Noodle Push: \(result?.outcome.rawValue ?? "?") (HTTP \(answer.status)"
                + (result?.apnsStatus.map { ", APNs \($0)" } ?? "") + (result?.reason.map { ", \(Self.shown($0))" } ?? "") + ")")
            if result?.outcome == .rateLimited, ["addressLimit", "hubLimit"].contains(result?.reason ?? "") {
                pausedUntil = now().addingTimeInterval(Self.rateLimitPause)
            }
        } catch {
            result = nil
            log("Could not ring a device away through Noodle Push: \((error as? URLError)?.code.rawValue.description ?? "no answer")")
        }
        return result
    }

    /// Whether the device's grant can never ring again, so the Hub forgets it. The device then sees in its
    /// status that the Hub has none and registers with Push again on its next connect.
    static func dropsGrant(_ result: PushRingResult?) -> Bool {
        switch result?.outcome {
        case .unregistered, .registrationExpired, .grantExpired: true
        // Refused for the grant itself, as when Push no longer opens the sealed token. Other refusals, such as a
        // stale timestamp from this Hub's clock, a new grant would not mend; they are logged.
        case .rejected: ["badSealedToken", "badGrant", "grantTooLong"].contains(result?.reason ?? "")
        default: false
        }
    }

    /// An answer that was not Push's JSON, as from a proxy in between, read by its status alone.
    private static func result(forStatus status: Int) -> PushRingResult? {
        switch status {
        case 200: PushRingResult(outcome: .sent)
        case 410: PushRingResult(outcome: .unregistered)
        case 429: PushRingResult(outcome: .rateLimited)
        default: nil
        }
    }

    /// Push's reasons are short names such as `BadDeviceToken`; anything else is left out of the log.
    private static func shown(_ reason: String) -> String {
        reason.count <= 40 && reason.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? reason : "?"
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HubCore", category: "Calls")
}
