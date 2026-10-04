import Foundation
import HubLink
import NoodleCore

/// What an admin may do from one of their devices. Only the Hub itself makes admins, and admins
/// manage only users who are not admins, so no device can raise, remove or lock out an admin,
/// its own user included. The role is checked against the Hub's record before every change.
@MainActor struct HubAdmin {
    private let id: UUID
    private let access: HubAccess
    private let isConnected: (HubDevice) -> Bool

    init(_ user: HubUser, access: HubAccess, isConnected: @escaping (HubDevice) -> Bool = { _ in false }) throws {
        id = user.id
        self.access = access
        self.isConnected = isConnected
        try checkAdmin()
    }

    func users() -> LinkUsers {
        LinkUsers(users: access.users.map(link), plans: access.plans.map { LinkPlanChoice(id: $0.id, name: $0.name) })
    }

    func addUser(_ draft: LinkUserDraft) throws -> LinkUser {
        try checkAdmin()
        let plan = try draft.plan.map(self.plan)
        let user = try access.addUser(named: draft.name ?? "")
        try apply(name: nil, plan: plan, canPairDevices: draft.canPairDevices, to: user)
        return try link(current(user.id))
    }

    func updateUser(_ id: UUID, with draft: LinkUserDraft) throws -> LinkUser {
        let user = try managedUser(id)
        let plan = try draft.plan.map(self.plan)
        let name = try draft.name.map(ConversationName.validated)
        try apply(name: name, plan: plan, canPairDevices: draft.canPairDevices, to: user)
        return try link(current(id))
    }

    /// A user an admin may remove or invite a device for.
    func managedUser(_ id: UUID) throws -> HubUser {
        try checkAdmin()
        let user = try current(id)
        guard !user.isAdmin else { throw LinkError("“\(user.name)” is an admin. Admins are managed on the Hub itself.") }
        return user
    }

    /// A device an admin may unpair.
    func managedDevice(_ id: UUID) throws -> HubDevice {
        try checkAdmin()
        guard let device = access.devices.first(where: { $0.id == id }), let user = access.user(for: device) else {
            throw LinkError("That device is no longer paired with this Hub.")
        }
        _ = try managedUser(user.id)
        return device
    }

    private func checkAdmin() throws {
        guard !access.isPersonal, access.users.first(where: { $0.id == id })?.isAdmin == true else {
            throw LinkError("Only an admin of this Hub can do that.")
        }
    }

    private func current(_ id: UUID) throws -> HubUser {
        guard let user = access.users.first(where: { $0.id == id }) else { throw LinkError("That user is no longer on this Hub.") }
        return user
    }

    private func plan(_ id: UUID) throws -> HubPlan {
        guard let plan = access.plans.first(where: { $0.id == id }) else { throw LinkError("That plan is no longer on this Hub.") }
        return plan
    }

    /// Takes only what was checked already, so a change is kept whole or not at all.
    private func apply(name: String?, plan: HubPlan?, canPairDevices: Bool?, to user: HubUser) throws {
        if let name, name != user.name { try access.rename(user, to: name) }
        if let plan, plan.id != user.plan { access.move(user, to: plan) }
        if let canPairDevices, canPairDevices != user.canPairDevices { access.setCanPairDevices(canPairDevices, for: user) }
    }

    private func link(_ user: HubUser) -> LinkUser {
        LinkUser(id: user.id, name: user.name, plan: user.plan, canPairDevices: user.canPairDevices, isAdmin: user.isAdmin,
                 devices: access.devices(of: user).map {
                     LinkUserDevice(id: $0.id, name: $0.name, paired: $0.paired, lastSeen: $0.lastSeen, isConnected: isConnected($0))
                 },
                 avatar: user.avatar)
    }
}
