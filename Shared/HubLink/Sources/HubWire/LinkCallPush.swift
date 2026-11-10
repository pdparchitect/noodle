import CryptoKit
import Foundation
@_exported import PushWire

// Ringing a phone that is away from the Hub, or has Noodle closed, through Noodle Push (`Push/`), which
// wakes it with a VoIP push. The phone registers its VoIP token with Push and gets it back sealed; it
// gives each Hub a `CallGrant` for that sealed token, signed with the key it paired with that Hub, and a
// key of its own for that Hub to encrypt who is calling. The Hub then rings with a `PushRingRequest` it
// signs with its own key. PushWire holds the bytes all three sides must agree on.

/// What a device sends with `callPush`: a grant naming this Hub, and the key the Hub encrypts who is
/// calling with. No grant stops the Hub ringing the device through Push.
public struct LinkCallPush: Codable, Equatable, Sendable {
    public var grant: CallGrant?
    /// 32 random bytes the device made for this Hub alone.
    public var callKey: Data?

    public init(grant: CallGrant?, callKey: Data?) {
        self.grant = grant
        self.callKey = callKey
    }

    /// Where Noodle Push answers.
    public static let service = URL(string: "https://push.usenoodle.app")!
    /// How long a grant the phone signs lasts. Push accepts up to 15 days; the day between covers clocks.
    public static let grantLifetime: TimeInterval = 14 * 86_400
    /// The longest grant a Hub keeps, as Push accepts no longer.
    public static let longestGrant: TimeInterval = 15 * 86_400
    /// A grant with less than this left is renewed when the phone next connects.
    public static let renewal: TimeInterval = 7 * 86_400
    public static let callKeyLength = 32
    /// The most of a sealed token a Hub keeps; Push's are a little over 100 bytes.
    static let largestSealed = 1_024

    /// The grant and key a Hub may keep from the device with `device`: signed by that device, naming
    /// `hub`, current, no longer than Push accepts, with a key of the right length. Nil when the device
    /// asks to stop.
    public func checked(device: LinkPublicKey, hub: LinkPublicKey, now: Date) throws -> (grant: CallGrant, callKey: Data)? {
        guard let grant else { return nil }
        guard let callKey, callKey.count == Self.callKeyLength, (1...Self.largestSealed).contains(grant.sealed.count) else {
            throw LinkError("The call grant could not be read.")
        }
        guard grant.deviceKey == device.x963, grant.hubKey == hub.x963, grant.hasValidSignature else {
            throw LinkError("The call grant is not this device's for this Hub.")
        }
        let seconds = Int64(now.timeIntervalSince1970)
        guard grant.expiresAt > seconds, grant.expiresAt <= seconds + Int64(Self.longestGrant) else {
            throw LinkError("The call grant has expired or lasts too long.")
        }
        return (grant, callKey)
    }
}

/// Who is calling, as the phone shows it before it reaches the Hub. It travels in `PushRingRequest.blob`,
/// encrypted with the device's call key for that Hub, so neither Push nor Apple can read it. The call's
/// ID is authenticated with it, so a blob from one call cannot name the caller of another.
public struct LinkCallPushCaller: Codable, Equatable, Sendable {
    public var botID: UUID
    public var botName: String
    /// The bot's conversation with the person, where the call is answered.
    public var conversationID: UUID
    /// Seconds since 1970 when the Hub stops ringing. The phone rings until the earlier of this and the push's own
    /// end, which Push sets and could change; this one only the Hub could.
    public var expiresAt: Int64?

    /// The longest name sent, which keeps the blob far below the 2 KB Push accepts.
    public static let longestName = 100

    public init(botID: UUID, botName: String, conversationID: UUID, expiresAt: Int64? = nil) {
        self.botID = botID
        self.botName = String(botName.prefix(Self.longestName))
        self.conversationID = conversationID
        self.expiresAt = expiresAt
    }

    /// AES-GCM with the call key: nonce, ciphertext and tag together.
    public func sealed(callID: UUID, with callKey: Data) throws -> Data {
        guard callKey.count == LinkCallPush.callKeyLength else { throw LinkError("The call key could not be read.") }
        let box = try AES.GCM.seal(try JSONEncoder().encode(self), using: SymmetricKey(data: callKey),
                                   authenticating: Self.associatedData(callID))
        guard let combined = box.combined else { throw LinkError("The caller could not be sealed.") }
        return combined
    }

    /// The caller in `blob`, or nil when it was not sealed with `callKey` for this call.
    public static func open(_ blob: Data, callID: UUID, with callKey: Data) -> LinkCallPushCaller? {
        guard callKey.count == LinkCallPush.callKeyLength, let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: callKey), authenticating: associatedData(callID))
        else { return nil }
        return try? JSONDecoder().decode(LinkCallPushCaller.self, from: plain)
    }

    private static func associatedData(_ callID: UUID) -> Data {
        PushSigning.message("noodle-push-caller-v1", [withUnsafeBytes(of: callID.uuid) { Data($0) }])
    }
}
