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
    /// The models a bot may use on each harness; a harness missing here may use any, the harness default included.
    public var models: [HubHarness: Set<String>]

    public init(id: UUID = UUID(), name: String, harnesses: Set<HubHarness> = [], models: [HubHarness: Set<String>] = [:]) {
        self.id = id
        self.name = name
        self.harnesses = harnesses
        self.models = models
    }

    private enum CodingKeys: String, CodingKey { case id, name, harnesses, models }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        harnesses = try c.decode(Set<HubHarness>.self, forKey: .harnesses)
        models = try c.decodeIfPresent([HubHarness: Set<String>].self, forKey: .models) ?? [:]
    }

    public var isDefault: Bool { id == Self.defaultID }
}

/// A person the Hub lends harnesses to. Each user is on exactly one plan.
public struct HubUser: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var plan: UUID
    /// Whether their devices may ask for invitations for more of their own devices.
    public var canPairDevices: Bool
    /// Whether they may manage the users who are not admins from their devices. Only the Hub itself makes admins.
    public var isAdmin: Bool

    public init(id: UUID = UUID(), name: String, plan: UUID = HubPlan.defaultID, canPairDevices: Bool = true, isAdmin: Bool = false) {
        self.id = id
        self.name = name
        self.plan = plan
        self.canPairDevices = canPairDevices
        self.isAdmin = isAdmin
    }

    private enum CodingKeys: String, CodingKey { case id, name, plan, canPairDevices, isAdmin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        plan = try c.decode(UUID.self, forKey: .plan)
        canPairDevices = try c.decodeIfPresent(Bool.self, forKey: .canPairDevices) ?? true
        isAdmin = try c.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
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
    /// Where the device hears of unread replies while away, if it asked to.
    public var pushTopic: String?

    public init(id: UUID = UUID(), user: UUID, name: String, key: LinkPublicKey, paired: Date, lastSeen: Date? = nil,
                pushTopic: String? = nil) {
        self.id = id
        self.user = user
        self.name = name
        self.key = key
        self.paired = paired
        self.lastSeen = lastSeen
        self.pushTopic = pushTopic
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
    @ObservationIgnored private let url: URL
    /// Runs when a bot's, computer's or browser's owner, or an owner's name, changed.
    @ObservationIgnored public var onOwnersChange: (() -> Void)?
    /// Where changes to users and devices are kept, for the Hub's Activity window.
    @ObservationIgnored public var log: HubActivityLog?
    /// Who the changes being made now are made by.
    @ObservationIgnored public private(set) var actor = HubActor.thisMac

    private struct Stored: Codable {
        var users: [HubUser]
        var plans: [HubPlan]
        var devices: [HubDevice]?
        var botOwners: [UUID: UUID]?
        var connectionOwners: [UUID: UUID]?
        var computerOwners: [UUID: UUID]?
        var browserOwners: [UUID: UUID]?
    }

    /// Noodle serving its own owner: one user, who owns every bot and companion on the Mac and
    /// may use every harness. Nobody else can be added.
    public let isPersonal: Bool

    public init(url: URL, personal: Bool = false) {
        self.url = url
        isPersonal = personal
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            users = stored.users
            plans = stored.plans
            devices = stored.devices ?? []
            botOwners = stored.botOwners ?? [:]
            connectionOwners = stored.connectionOwners ?? [:]
            computerOwners = stored.computerOwners ?? [:]
            browserOwners = stored.browserOwners ?? [:]
        }
        if !plans.contains(where: \.isDefault) {
            plans.insert(HubPlan(id: HubPlan.defaultID, name: "Default"), at: 0)
        }
        // A plan lost from the file must not leave its users with nothing to fall back on.
        for index in users.indices where !plans.contains(where: { $0.id == users[index].plan }) {
            users[index].plan = HubPlan.defaultID
        }
        if personal, users.isEmpty {
            users = [HubUser(name: NSFullUserName().isEmpty ? "Me" : NSFullUserName())]
            save()
        }
    }

    public func harnesses(for user: HubUser) -> Set<HubHarness> {
        if isPersonal { return Set(HarnessProvider.allCases.map { HubHarness(provider: $0, profile: nil) }) }
        return plans.first { $0.id == user.plan }?.harnesses ?? []
    }

    /// Whether the user may run a bot on `harness`; the owner of a personal Mac may run any.
    public func lends(_ harness: HubHarness, to user: HubUser) -> Bool {
        guard let current = users.first(where: { $0.id == user.id }) else { return false }
        return isPersonal || harnesses(for: current).contains(harness)
    }

    /// The models the user's plan allows on `harness`; nil when any may be used.
    public func models(on harness: HubHarness, for user: HubUser) -> Set<String>? {
        guard !isPersonal else { return nil }
        return plans.first { $0.id == user.plan }?.models[harness]
    }

    /// Whether the user may run a bot on `harness` with `model`, nil being the harness default.
    public func lends(_ harness: HubHarness, model: String?, to user: HubUser) -> Bool {
        guard lends(harness, to: user), let current = users.first(where: { $0.id == user.id }) else { return false }
        guard let allowed = models(on: harness, for: current) else { return true }
        return model.map(allowed.contains) ?? false
    }

    /// The owner of everything on a personal Mac.
    private var personalOwner: UUID? { isPersonal ? users.first?.id : nil }

    /// Makes the changes in `body` as `actor` rather than as this Mac, for the log.
    public func acting<T>(as actor: HubActor, _ body: () throws -> T) rethrows -> T {
        let previous = self.actor
        self.actor = actor
        defer { self.actor = previous }
        return try body()
    }

    /// Keeps a change, or a refused attempt, in the log, as made by whoever acts now.
    public func note(_ what: String, refusal: String? = nil, about users: [UUID]) {
        log?.record(who: actor.who, what: what, refusal: refusal, users: Set(users + [actor.user].compactMap { $0 }))
    }

    @discardableResult public func addUser(named name: String) throws -> HubUser {
        guard !isPersonal else { throw LinkError("This Mac is only yours; nobody else can be added.") }
        let user = HubUser(name: try ConversationName.validated(name))
        users.append(user)
        save()
        note("Added \(user.name)", about: [user.id])
        return user
    }

    public func rename(_ user: HubUser, to name: String) throws {
        let name = try ConversationName.validated(name)
        guard let old = current(user), old.name != name else { return }
        update(user) { $0.name = name }
        note("Renamed \(old.name) to \(name)", about: [user.id])
        onOwnersChange?()
    }

    public func move(_ user: HubUser, to plan: HubPlan) {
        guard let plan = plans.first(where: { $0.id == plan.id }), let old = current(user), old.plan != plan.id else { return }
        update(user) { $0.plan = plan.id }
        note("Moved \(old.name) to the \(plan.name) plan", about: [user.id])
    }

    public func setCanPairDevices(_ canPairDevices: Bool, for user: HubUser) {
        guard let old = current(user), old.canPairDevices != canPairDevices else { return }
        update(user) { $0.canPairDevices = canPairDevices }
        note(canPairDevices ? "Let \(old.name) pair devices" : "Stopped \(old.name) pairing devices", about: [user.id])
    }

    /// Nobody is an admin on the owner's own Mac: there is nobody else to manage.
    public func setAdmin(_ isAdmin: Bool, for user: HubUser) {
        guard !isPersonal, let old = current(user), old.isAdmin != isAdmin else { return }
        update(user) { $0.isAdmin = isAdmin }
        note(isAdmin ? "Made \(old.name) an admin" : "Made \(old.name) no longer an admin", about: [user.id])
    }

    /// Their devices go too. Remove a user through `Hub.remove`, which deletes their bots and connections first.
    public func remove(_ user: HubUser) {
        guard let old = current(user) else { return }
        note("Removed \(old.name)", about: [user.id])
        users.removeAll { $0.id == user.id }
        devices.removeAll { $0.user == user.id }
        botOwners = botOwners.filter { $0.value != user.id }
        connectionOwners = connectionOwners.filter { $0.value != user.id }
        computerOwners = computerOwners.filter { $0.value != user.id }
        browserOwners = browserOwners.filter { $0.value != user.id }
        save()
    }

    public func owner(ofBot bot: UUID) -> UUID? { personalOwner ?? botOwners[bot] }

    public func bots(of user: HubUser) -> [UUID] {
        botOwners.filter { $0.value == user.id }.map(\.key)
    }

    public func setOwner(_ user: HubUser?, ofBot bot: UUID) {
        botOwners[bot] = user?.id
        save()
        onOwnersChange?()
    }

    public func owner(ofConnection connection: UUID) -> UUID? { personalOwner ?? connectionOwners[connection] }

    public func owner(ofComputer computer: UUID) -> UUID? { personalOwner ?? computerOwners[computer] }

    public func owner(ofBrowser browser: UUID) -> UUID? { personalOwner ?? browserOwners[browser] }

    public func setOwner(_ user: HubUser?, ofBrowser browser: UUID) {
        browserOwners[browser] = user?.id
        save()
        onOwnersChange?()
    }

    public func setOwner(_ user: HubUser?, ofComputer computer: UUID) {
        computerOwners[computer] = user?.id
        save()
        onOwnersChange?()
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
        note("Paired “\(name)” for \(current(user)?.name ?? user.name)", about: [user.id])
        return device
    }

    public func remove(_ device: HubDevice) {
        guard devices.contains(where: { $0.id == device.id }) else { return }
        devices.removeAll { $0.id == device.id }
        save()
        note("Unpaired “\(device.name)” from \(users.first { $0.id == device.user }?.name ?? "someone no longer on the Hub")",
             about: [device.user])
    }

    public func markSeen(_ device: HubDevice, at date: Date) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].lastSeen = date
        save()
    }

    public func setPushTopic(_ topic: String?, for device: HubDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }), devices[index].pushTopic != topic else { return }
        devices[index].pushTopic = topic
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
            if included { $0.harnesses.insert(harness) } else { $0.harnesses.remove(harness); $0.models[harness] = nil }
        }
    }

    /// Limits the models a bot may use on `harness`; nil, or none, lets it use any.
    public func setModels(_ models: Set<String>?, for harness: HubHarness, in plan: HubPlan) {
        update(plan) { $0.models[harness] = models?.isEmpty == false ? models : nil }
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
        for index in plans.indices {
            plans[index].harnesses = plans[index].harnesses.filter { $0.profile != profile }
            plans[index].models = plans[index].models.filter { $0.key.profile != profile }
        }
        save()
    }

    /// The Hub's own record of the user, which a passed-in copy may be behind.
    private func current(_ user: HubUser) -> HubUser? {
        users.first { $0.id == user.id }
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
                                                         browserOwners: browserOwners)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? AtomicFile.write(data, to: url)
    }
}
