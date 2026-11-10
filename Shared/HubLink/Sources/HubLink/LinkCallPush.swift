import Foundation
import HubWire
import PushWire

extension HubPairing {
    /// The phone's VoIP token for Noodle Push, signed with the key this device paired with this Hub. Each
    /// Hub gets a token sealed for its own key, so Hubs still cannot tell they share a device.
    public func pushRegistration(token: Data, environment: PushAPNsEnvironment, now: Date = Date()) throws -> PushRegistration {
        try PushRegistration.signed(token: token, environment: environment, timestamp: Int64(now.timeIntervalSince1970),
                                    by: identity().privateKey)
    }

    /// Lets this Hub ring the phone through Noodle Push until `expiresAt`, with the token Push sealed for
    /// `pushRegistration`.
    public func callGrant(sealed: Data, expiresAt: Date) throws -> CallGrant {
        guard let hub else { throw LinkError("This device has not joined a Noodle Hub.") }
        return try CallGrant.signed(sealed: sealed, hubKey: hub.key.x963, expiresAt: Int64(expiresAt.timeIntervalSince1970),
                                    by: identity().privateKey)
    }
}
