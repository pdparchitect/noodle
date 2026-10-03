import Foundation
import Observation

/// The users of a Hub where this device's user is an admin, as the Hub has them. Every change
/// goes to the Hub, which decides, and the list is read back from it afterwards.
@MainActor @Observable public final class HubUsers {
    public private(set) var users: [LinkUser] = []
    public private(set) var plans: [LinkPlanChoice] = []
    /// Why the last request failed, until one succeeds.
    public private(set) var error: String?
    /// Whether the Hub answered once, with the users or with why not.
    public private(set) var isLoaded = false
    @ObservationIgnored private let pairing: HubPairing

    public init(pairing: HubPairing) {
        self.pairing = pairing
    }

    public func load() async {
        do {
            guard case .users(let listed) = try await pairing.request(.users) else {
                throw LinkError("This Noodle Hub sent an answer this Noodle does not know. Update Noodle.")
            }
            users = listed.users
            plans = listed.plans
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoaded = true
    }

    public func planName(of user: LinkUser) -> String? {
        plans.first { $0.id == user.plan }?.name
    }

    public func add(named name: String) async -> LinkUser? {
        guard case .user(let added) = await change(.addUser(LinkUserDraft(name: name))) else { return nil }
        return added
    }

    public func rename(_ user: LinkUser, to name: String) async {
        await change(.updateUser(id: user.id, LinkUserDraft(name: name)))
    }

    public func move(_ user: LinkUser, to plan: UUID) async {
        await change(.updateUser(id: user.id, LinkUserDraft(plan: plan)))
    }

    public func setCanPairDevices(_ canPairDevices: Bool, for user: LinkUser) async {
        await change(.updateUser(id: user.id, LinkUserDraft(canPairDevices: canPairDevices)))
    }

    /// Removes the user with their devices and everything they keep on the Hub.
    public func remove(_ user: LinkUser) async {
        await change(.removeUser(id: user.id))
    }

    public func remove(_ device: LinkUserDevice) async {
        await change(.removeDevice(id: device.id))
    }

    public func invite(_ user: LinkUser) async -> LinkInvitation? {
        do {
            guard case .invitation(let invitation) = try await pairing.request(.inviteUser(id: user.id)) else { return nil }
            error = nil
            return invitation
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Sends the change, then reads the users back, so the list is the Hub's whatever it decided.
    @discardableResult private func change(_ request: LinkRequest) async -> LinkResponse? {
        let response: LinkResponse
        do {
            response = try await pairing.request(request)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
        await load()
        return response
    }
}
