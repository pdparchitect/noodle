import Foundation
import HubLink
import NoodleCore
import Observation

/// A harness the Hub can lend: its own login when `profile` is nil, otherwise one of its profiles.
public struct HubHarness: Codable, Hashable, Sendable {
    public var provider: HarnessProvider
    public var profile: UUID?

    public init(provider: HarnessProvider, profile: UUID?) {
        self.provider = provider
        self.profile = profile
    }
}

/// What the users on it may use.
public struct HubPlan: Identifiable, Codable, Hashable, Sendable {
    /// Always present and never deleted; new users start on it.
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public let id: UUID
    public var name: String
    public var harnesses: Set<HubHarness>

    public init(id: UUID = UUID(), name: String, harnesses: Set<HubHarness> = []) {
        self.id = id
        self.name = name
        self.harnesses = harnesses
    }

    public var isDefault: Bool { id == Self.defaultID }
}

/// A person the Hub lends harnesses to. Each user is on exactly one plan.
public struct HubUser: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var plan: UUID

    public init(id: UUID = UUID(), name: String, plan: UUID = HubPlan.defaultID) {
        self.id = id
        self.name = name
        self.plan = plan
    }
}

/// A paired device, known by the key it proved at pairing.
public struct HubDevice: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let user: UUID
    public var name: String
    public let key: LinkPublicKey
    public let paired: Date
    public var lastSeen: Date?

    public init(id: UUID = UUID(), user: UUID, name: String, key: LinkPublicKey, paired: Date, lastSeen: Date? = nil) {
        self.id = id
        self.user = user
        self.name = name
        self.key = key
        self.paired = paired
        self.lastSeen = lastSeen
    }
}

/// The Hub's users, their devices and plans, kept in one file beside its bots.
@MainActor @Observable public final class HubAccess {
    public private(set) var users: [HubUser] = []
    public private(set) var plans: [HubPlan] = []
    public private(set) var devices: [HubDevice] = []
    /// Which user each bot on the Hub belongs to.
    public private(set) var botOwners: [UUID: UUID] = [:]
    /// Which user each tool connection on the Hub belongs to.
    public private(set) var connectionOwners: [UUID: UUID] = [:]
    /// Which user each computer the Hub lends belongs to.
    public private(set) var computerOwners: [UUID: UUID] = [:]
    /// Which user each browser the Hub lends belongs to.
    public private(set) var browserOwners: [UUID: UUID] = [:]
    /// Which bot shared each noodlet. Noodle Applet does not know; the Hub opens a noodlet only
    /// from that bot's conversation.
    public private(set) var noodletBots: [UUID: UUID] = [:]
    @ObservationIgnored private let url: URL

    private struct Stored: Codable {
        var users: [HubUser]
        var plans: [HubPlan]
        var devices: [HubDevice]?
        var botOwners: [UUID: UUID]?
        var connectionOwners: [UUID: UUID]?
        var computerOwners: [UUID: UUID]?
        var browserOwners: [UUID: UUID]?
        var noodletBots: [UUID: UUID]?
    }

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            users = stored.users
            plans = stored.plans
            devices = stored.devices ?? []
            botOwners = stored.botOwners ?? [:]
            connectionOwners = stored.connectionOwners ?? [:]
            computerOwners = stored.computerOwners ?? [:]
            browserOwners = stored.browserOwners ?? [:]
            noodletBots = stored.noodletBots ?? [:]
        }
        if !plans.contains(where: \.isDefault) {
            plans.insert(HubPlan(id: HubPlan.defaultID, name: "Default"), at: 0)
        }
        // A plan lost from the file must not leave its users with nothing to fall back on.
        for index in users.indices where !plans.contains(where: { $0.id == users[index].plan }) {
            users[index].plan = HubPlan.defaultID
        }
    }

    public func harnesses(for user: HubUser) -> Set<HubHarness> {
        plans.first { $0.id == user.plan }?.harnesses ?? []
    }

    @discardableResult public func addUser(named name: String) throws -> HubUser {
        let user = HubUser(name: try ConversationName.validated(name))
        users.append(user)
        save()
        return user
    }

    public func rename(_ user: HubUser, to name: String) throws {
        let name = try ConversationName.validated(name)
        update(user) { $0.name = name }
    }

    public func move(_ user: HubUser, to plan: HubPlan) {
        guard plans.contains(where: { $0.id == plan.id }) else { return }
        update(user) { $0.plan = plan.id }
    }

    /// Their devices go too. Remove a user through `Hub.remove`, which deletes their bots and connections first.
    public func remove(_ user: HubUser) {
        users.removeAll { $0.id == user.id }
        devices.removeAll { $0.user == user.id }
        botOwners = botOwners.filter { $0.value != user.id }
        connectionOwners = connectionOwners.filter { $0.value != user.id }
        computerOwners = computerOwners.filter { $0.value != user.id }
        browserOwners = browserOwners.filter { $0.value != user.id }
        save()
    }

    public func owner(ofBot bot: UUID) -> UUID? { botOwners[bot] }

    public func bots(of user: HubUser) -> [UUID] {
        botOwners.filter { $0.value == user.id }.map(\.key)
    }

    public func setOwner(_ user: HubUser?, ofBot bot: UUID) {
        botOwners[bot] = user?.id
        save()
    }

    public func owner(ofConnection connection: UUID) -> UUID? { connectionOwners[connection] }

    public func owner(ofComputer computer: UUID) -> UUID? { computerOwners[computer] }

    public func owner(ofBrowser browser: UUID) -> UUID? { browserOwners[browser] }

    public func bot(ofNoodlet noodlet: UUID) -> UUID? { noodletBots[noodlet] }

    /// The first bot to share a noodlet keeps it; another bot sharing the same one does not take it over.
    public func setBot(_ bot: UUID, ofNoodlet noodlet: UUID) {
        guard noodletBots[noodlet] == nil else { return }
        noodletBots[noodlet] = bot
        save()
    }

    public func forgetNoodlets(of bot: UUID) {
        noodletBots = noodletBots.filter { $0.value != bot }
        save()
    }

    public func setOwner(_ user: HubUser?, ofBrowser browser: UUID) {
        browserOwners[browser] = user?.id
        save()
    }

    public func setOwner(_ user: HubUser?, ofComputer computer: UUID) {
        computerOwners[computer] = user?.id
        save()
    }

    public func setOwner(_ user: HubUser?, ofConnection connection: UUID) {
        connectionOwners[connection] = user?.id
        save()
    }

    public func user(for device: HubDevice) -> HubUser? {
        users.first { $0.id == device.user }
    }

    public func devices(of user: HubUser) -> [HubDevice] {
        devices.filter { $0.user == user.id }
    }

    public func device(for key: LinkPublicKey) -> HubDevice? {
        devices.first { $0.key == key }
    }

    /// A key pairs once; pairing it again moves it to the new user and name.
    @discardableResult public func addDevice(named name: String, key: LinkPublicKey, for user: HubUser, at date: Date) -> HubDevice {
        devices.removeAll { $0.key == key }
        let device = HubDevice(user: user.id, name: name, key: key, paired: date, lastSeen: date)
        devices.append(device)
        save()
        return device
    }

    public func remove(_ device: HubDevice) {
        devices.removeAll { $0.id == device.id }
        save()
    }

    public func markSeen(_ device: HubDevice, at date: Date) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].lastSeen = date
        save()
    }

    @discardableResult public func addPlan(named name: String) throws -> HubPlan {
        let plan = HubPlan(name: try ConversationName.validated(name))
        plans.append(plan)
        save()
        return plan
    }

    public func rename(_ plan: HubPlan, to name: String) throws {
        let name = try ConversationName.validated(name)
        update(plan) { $0.name = name }
    }

    public func set(_ harness: HubHarness, included: Bool, in plan: HubPlan) {
        update(plan) {
            if included { $0.harnesses.insert(harness) } else { $0.harnesses.remove(harness) }
        }
    }

    /// Users on a deleted plan go back to Default.
    public func delete(_ plan: HubPlan) {
        guard !plan.isDefault else { return }
        plans.removeAll { $0.id == plan.id }
        for index in users.indices where users[index].plan == plan.id { users[index].plan = HubPlan.defaultID }
        save()
    }

    /// Called when a harness profile is deleted.
    public func removeProfile(_ profile: UUID) {
        for index in plans.indices { plans[index].harnesses = plans[index].harnesses.filter { $0.profile != profile } }
        save()
    }

    private func update(_ user: HubUser, _ change: (inout HubUser) -> Void) {
        guard let index = users.firstIndex(where: { $0.id == user.id }) else { return }
        change(&users[index])
        save()
    }

    private func update(_ plan: HubPlan, _ change: (inout HubPlan) -> Void) {
        guard let index = plans.firstIndex(where: { $0.id == plan.id }) else { return }
        change(&plans[index])
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Stored(users: users, plans: plans, devices: devices, botOwners: botOwners,
                                                         connectionOwners: connectionOwners, computerOwners: computerOwners,
                                                         browserOwners: browserOwners, noodletBots: noodletBots)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? AtomicFile.write(data, to: url)
    }
}
