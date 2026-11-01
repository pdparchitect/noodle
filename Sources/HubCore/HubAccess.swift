import Foundation
import HubLink
import ImageIO
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
    /// How many computers each user on it may keep; nil for any number.
    public var computerLimit: Int?
    /// How many browsers each user on it may keep; nil for any number.
    public var browserLimit: Int?
    /// How many tokens each user's bots on it may use in a period; nil for any number.
    public var tokenLimit: HubTokenLimit?
    /// The kinds of computer each user on it may make, by the template Noodle Computer makes them from; nil for every kind.
    public var computerTypes: Set<String>?

    public init(id: UUID = UUID(), name: String, harnesses: Set<HubHarness> = [], models: [HubHarness: Set<String>] = [:],
                computerLimit: Int? = nil, browserLimit: Int? = nil, tokenLimit: HubTokenLimit? = nil, computerTypes: Set<String>? = nil) {
        self.id = id
        self.name = name
        self.harnesses = harnesses
        self.models = models
        self.computerLimit = computerLimit
        self.browserLimit = browserLimit
        self.tokenLimit = tokenLimit
        self.computerTypes = computerTypes
    }

    private enum CodingKeys: String, CodingKey { case id, name, harnesses, models, computerLimit, browserLimit, tokenLimit, computerTypes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        harnesses = try c.decode(Set<HubHarness>.self, forKey: .harnesses)
        models = try c.decodeIfPresent([HubHarness: Set<String>].self, forKey: .models) ?? [:]
        computerLimit = try c.decodeIfPresent(Int.self, forKey: .computerLimit)
        browserLimit = try c.decodeIfPresent(Int.self, forKey: .browserLimit)
        // A period a later Hub knows and this one does not must not cost the file its users.
        tokenLimit = try? c.decodeIfPresent(HubTokenLimit.self, forKey: .tokenLimit)
        // Plans saved before computer types let their users make every kind.
        computerTypes = try c.decodeIfPresent(Set<String>.self, forKey: .computerTypes)
    }

    public var isDefault: Bool { id == Self.defaultID }
}

/// How many tokens each user's bots may use in any period of the same length up to now: a rolling
/// window, so tokens count again for nobody until they are older than the period.
public struct HubTokenLimit: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case hours, days, weeks, months

        /// A month is 30 days, so every period is as long as the last.
        var seconds: TimeInterval {
            switch self {
            case .hours: 3600
            case .days: 86_400
            case .weeks: 7 * 86_400
            case .months: 30 * 86_400
            }
        }

        /// "hour" or "hours".
        public func name(count: Int) -> String { count == 1 ? String(rawValue.dropLast()) : rawValue }
    }

    public var tokens: Int
    /// How many units the period lasts.
    public var length: Int
    public var unit: Unit

    public init(tokens: Int, length: Int = 1, unit: Unit = .weeks) {
        self.tokens = max(1, tokens)
        self.length = max(1, length)
        self.unit = unit
    }

    public var period: TimeInterval { Double(length) * unit.seconds }

    /// What follows "per": "7 days", "month".
    public var periodName: String { length == 1 ? unit.name(count: 1) : "\(length) \(unit.name(count: length))" }
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
    /// Suspended users keep their data and devices but cannot use the Hub.
    public var isSuspended: Bool = false
    /// The picture they chose, its image kept apart under its digest. Nil shows their initials.
    public var avatar: LinkAvatar?
    /// How their groups that keep the default notify them. Nil for every reply.
    public var groupNotifications: LinkNotifications?

    public init(id: UUID = UUID(), name: String, plan: UUID = HubPlan.defaultID, canPairDevices: Bool = true, isAdmin: Bool = false) {
        self.id = id
        self.name = name
        self.plan = plan
        self.canPairDevices = canPairDevices
        self.isAdmin = isAdmin
    }

    private enum CodingKeys: String, CodingKey { case id, name, plan, canPairDevices, isAdmin, isSuspended, avatar, groupNotifications }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        plan = try c.decode(UUID.self, forKey: .plan)
        canPairDevices = try c.decodeIfPresent(Bool.self, forKey: .canPairDevices) ?? true
        isAdmin = try c.decodeIfPresent(Bool.self, forKey: .isAdmin) ?? false
        isSuspended = try c.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false
        avatar = try c.decodeIfPresent(LinkAvatar.self, forKey: .avatar)
        groupNotifications = try c.decodeIfPresent(LinkNotifications.self, forKey: .groupNotifications)
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
    /// How to ring the device through Noodle Push while it is away, if it gave the Hub a grant. Missing in
    /// files from before, which reads as none: the device sends one when it next connects.
    public var callPush: HubCallPush?

    public init(id: UUID = UUID(), user: UUID, name: String, key: LinkPublicKey, paired: Date, lastSeen: Date? = nil,
                pushTopic: String? = nil, callPush: HubCallPush? = nil) {
        self.id = id
        self.user = user
        self.name = name
        self.key = key
        self.paired = paired
        self.lastSeen = lastSeen
        self.pushTopic = pushTopic
        self.callPush = callPush
    }
}

/// A device's grant to ring it through Noodle Push, which names this Hub's key, and the key it gave the Hub
/// to encrypt who is calling. Only Push can open the token inside the grant.
public struct HubCallPush: Codable, Hashable, Sendable {
    public var grant: CallGrant
    public var callKey: Data

    public init(grant: CallGrant, callKey: Data) {
        self.grant = grant
        self.callKey = callKey
    }

    public var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(grant.expiresAt)) }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(grant.signature)
        hasher.combine(callKey)
    }
}

/// The Hub's users, their devices and plans, kept in one file beside its bots.
@MainActor @Observable public final class HubAccess {
    public private(set) var users: [HubUser] = []
    public private(set) var plans: [HubPlan] = []
    public private(set) var devices: [HubDevice] = []
    /// Which user each bot on the Hub belongs to.
    public private(set) var botOwners: [UUID: UUID] = [:]
    /// The device each bot that runs on its owner's device, rather than here, runs on.
    public private(set) var botHosts: [UUID: UUID] = [:]
    /// Which user each tool connection on the Hub belongs to.
    public private(set) var connectionOwners: [UUID: UUID] = [:]
    /// Which user each computer the Hub lends belongs to.
    public private(set) var computerOwners: [UUID: UUID] = [:]
    /// Which user each browser the Hub lends belongs to.
    public private(set) var browserOwners: [UUID: UUID] = [:]
    @ObservationIgnored private let url: URL
    /// Runs when a bot's, computer's or browser's owner, or an owner's name, changed.
    @ObservationIgnored public var onOwnersChange: (() -> Void)?
    /// Runs when the token limit someone is on may have changed: a plan's limit, or a user's plan.
    @ObservationIgnored public var onTokenLimitsChange: (() -> Void)?
    /// Runs synchronously so running bots stop before suspension returns.
    @ObservationIgnored public var onSuspensionChange: (() -> Void)?
    /// Where changes to users and devices are kept, for the Hub's Activity window.
    @ObservationIgnored public var log: HubActivityLog?
    /// Who the changes being made now are made by.
    @ObservationIgnored public private(set) var actor = HubActor.thisMac

    private struct Stored: Codable {
        var users: [HubUser]
        var plans: [HubPlan]
        var devices: [HubDevice]?
        var botOwners: [UUID: UUID]?
        var botHosts: [UUID: UUID]?
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
            botHosts = stored.botHosts ?? [:]
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
        guard let user = current(user), !user.isSuspended else { return [] }
        if isPersonal { return Set(HarnessProvider.allCases.map { HubHarness(provider: $0, profile: nil) }) }
        return plans.first { $0.id == user.plan }?.harnesses ?? []
    }

    /// Whether the user may run a bot on `harness`; the owner of a personal Mac may run any.
    public func lends(_ harness: HubHarness, to user: HubUser) -> Bool {
        guard let current = users.first(where: { $0.id == user.id }), !current.isSuspended else { return false }
        return isPersonal || harnesses(for: current).contains(harness)
    }

    /// The models the user's plan allows on `harness`; nil when any may be used.
    public func models(on harness: HubHarness, for user: HubUser) -> Set<String>? {
        guard !isPersonal else { return nil }
        return plans.first { $0.id == user.plan }?.models[harness]
    }

    /// How many computers the user's plan lets them keep; nil when any number.
    public func computerLimit(for user: HubUser) -> Int? {
        guard !isPersonal, let current = current(user) else { return nil }
        return plans.first { $0.id == current.plan }?.computerLimit
    }

    /// The kinds of computer the user's plan lets them make; nil when every kind.
    public func computerTypes(for user: HubUser) -> Set<String>? {
        guard !isPersonal, let current = current(user) else { return nil }
        return plans.first { $0.id == current.plan }?.computerTypes
    }

    /// Whether the user's plan lets them make a computer from `template`; one of no named kind only when it allows every kind.
    public func allowsComputerType(_ template: String?, for user: HubUser) -> Bool {
        guard let allowed = computerTypes(for: user) else { return true }
        return template.map(allowed.contains) ?? false
    }

    /// How many browsers the user's plan lets them keep; nil when any number.
    public func browserLimit(for user: HubUser) -> Int? {
        guard !isPersonal, let current = current(user) else { return nil }
        return plans.first { $0.id == current.plan }?.browserLimit
    }

    /// How many tokens the user's plan lets their bots use in a period; nil when any number.
    public func tokenLimit(for user: HubUser) -> HubTokenLimit? {
        guard !isPersonal, let current = current(user) else { return nil }
        return plans.first { $0.id == current.plan }?.tokenLimit
    }

    /// Why a user at their plan's limit cannot make another computer or browser.
    static func limitReached(_ limit: Int, _ one: String, _ many: String) -> LinkError {
        switch limit {
        case 0: LinkError("Your plan does not include \(many).")
        case 1: LinkError("Your plan allows up to 1 \(one). Delete it to make another.")
        default: LinkError("Your plan allows up to \(limit) \(many). Delete one to make another.")
        }
    }

    /// Whether the user may run a bot on `harness` with `model`, nil being the harness default.
    public func lends(_ harness: HubHarness, model: String?, to user: HubUser) -> Bool {
        guard lends(harness, to: user), let current = users.first(where: { $0.id == user.id }) else { return false }
        guard let allowed = models(on: harness, for: current) else { return true }
        return model.map(allowed.contains) ?? true
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
        onTokenLimitsChange?()
    }

    public func setCanPairDevices(_ canPairDevices: Bool, for user: HubUser) {
        guard let old = current(user), old.canPairDevices != canPairDevices else { return }
        update(user) { $0.canPairDevices = canPairDevices }
        note(canPairDevices ? "Let \(old.name) pair devices" : "Stopped \(old.name) pairing devices", about: [user.id])
    }

    public func setSuspended(_ suspended: Bool, for user: HubUser) {
        guard !isPersonal, let old = current(user), old.isSuspended != suspended else { return }
        update(user) { $0.isSuspended = suspended }
        note(suspended ? "Suspended \(old.name)" : "Restored access for \(old.name)", about: [user.id])
        onSuspensionChange?()
    }

    /// Nobody is an admin on the owner's own Mac: there is nobody else to manage.
    public func setAdmin(_ isAdmin: Bool, for user: HubUser) {
        guard !isPersonal, let old = current(user), old.isAdmin != isAdmin else { return }
        update(user) { $0.isAdmin = isAdmin }
        note(isAdmin ? "Made \(old.name) an admin" : "Made \(old.name) no longer an admin", about: [user.id])
    }

    /// The largest picture of a person the Hub keeps, well within a request. Devices send 512 pixels at most, far smaller.
    public static let maxPictureBytes = 512 * 1024

    /// Sets the user's picture, or with nil their initials. An image sent as its digest alone keeps the one they have.
    public func setAvatar(_ avatar: LinkAvatar?, for user: HubUser) throws {
        guard let old = current(user) else { return }
        var kept = avatar
        if var avatar {
            if let symbol = avatar.symbol, symbol.isEmpty || symbol.count > 64 { throw LinkError("That symbol cannot be used.") }
            if let image = avatar.image {
                guard image.count <= Self.maxPictureBytes else { throw LinkError("Choose a smaller picture.") }
                guard let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) > 0,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw LinkError("That picture cannot be used.") }
                avatar.imageDigest = LinkPicture.digest(image)
                try FileManager.default.createDirectory(at: picturesURL, withIntermediateDirectories: true)
                try AtomicFile.write(image, to: pictureURL(of: user.id))
            } else if let digest = avatar.imageDigest, digest != old.avatar?.imageDigest {
                throw LinkError("Send the picture again.")
            }
            avatar.image = nil
            kept = avatar
        }
        if kept?.imageDigest == nil { try? FileManager.default.removeItem(at: pictureURL(of: user.id)) }
        guard kept != old.avatar else { return }
        update(user) { $0.avatar = kept }
        note("\(old.name) changed their picture", about: [user.id])
    }

    /// Sets how the user's groups that keep the default notify them: every reply, or only those naming them.
    public func setGroupNotifications(_ level: LinkNotifications, for user: HubUser) throws {
        guard level == .all || level == .mentions else { throw LinkError("Choose All Messages or Mentions Only.") }
        guard let old = current(user) else { return }
        let kept: LinkNotifications? = level == .all ? nil : level
        guard kept != old.groupNotifications else { return }
        update(user) { $0.groupNotifications = kept }
    }

    /// The user's picture, its image left out.
    public func avatar(of user: UUID) -> LinkAvatar? {
        users.first { $0.id == user }?.avatar
    }

    /// The image of the user's picture, if they chose one.
    public func picture(of user: UUID) -> Data? {
        guard avatar(of: user)?.imageDigest != nil else { return nil }
        return try? Data(contentsOf: pictureURL(of: user))
    }

    /// Their devices go too. Remove a user through `Hub.remove`, which deletes their bots and connections first.
    public func remove(_ user: HubUser) {
        guard let old = current(user) else { return }
        note("Removed \(old.name)", about: [user.id])
        try? FileManager.default.removeItem(at: pictureURL(of: user.id))
        users.removeAll { $0.id == user.id }
        devices.removeAll { $0.user == user.id }
        botOwners = botOwners.filter { $0.value != user.id }
        botHosts = botHosts.filter { botOwners[$0.key] != nil }
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

    /// The device a bot runs on, when it runs on one of its owner's devices rather than here.
    public func host(ofBot bot: UUID) -> UUID? { botHosts[bot] }

    public func setHost(_ device: HubDevice?, ofBot bot: UUID) {
        botHosts[bot] = device?.id
        save()
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

    public func setCallPush(_ push: HubCallPush?, for device: HubDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }), devices[index].callPush != push else { return }
        devices[index].callPush = push
        save()
    }

    /// Forgets a grant Push refused, unless the device has sent another meanwhile.
    public func dropCallPush(_ push: HubCallPush, for device: HubDevice) {
        guard let current = devices.first(where: { $0.id == device.id }), current.callPush == push else { return }
        setCallPush(nil, for: current)
    }

    @discardableResult public func addPlan(named name: String) throws -> HubPlan {
        let plan = HubPlan(name: try ConversationName.validated(name))
        plans.append(plan)
        save()
        return plan
    }

    /// A new plan that lends what `plan` lends, with its limits, named “Family Copy”, or “Family Copy 2” and on when
    /// that is taken. Nobody is on it yet; the copy of Default is an ordinary plan.
    @discardableResult public func duplicate(_ plan: HubPlan) throws -> HubPlan {
        guard let original = plans.first(where: { $0.id == plan.id }) else { throw LinkError("That plan is no longer on this Hub.") }
        let taken = Set(plans.map(\.name))
        let name = (1...).lazy.map { number in
            let suffix = number == 1 ? " Copy" : " Copy \(number)"
            return String(original.name.prefix(ConversationName.maximumLength - suffix.count)) + suffix
        }.first { !taken.contains($0) }!
        let copy = HubPlan(name: name, harnesses: original.harnesses, models: original.models, computerLimit: original.computerLimit,
                           browserLimit: original.browserLimit, tokenLimit: original.tokenLimit, computerTypes: original.computerTypes)
        plans.append(copy)
        save()
        return copy
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

    /// Limits the computers each user on the plan may keep; nil lets them keep any number.
    public func setComputerLimit(_ limit: Int?, in plan: HubPlan) {
        update(plan) { $0.computerLimit = limit.map { max(0, $0) } }
    }

    /// Limits the kinds of computer each user on the plan may make; nil lets them make every kind.
    /// Computers they already have stay theirs to use.
    public func setComputerTypes(_ types: Set<String>?, in plan: HubPlan) {
        update(plan) { $0.computerTypes = types }
    }

    /// Limits the browsers each user on the plan may keep; nil lets them keep any number.
    public func setBrowserLimit(_ limit: Int?, in plan: HubPlan) {
        update(plan) { $0.browserLimit = limit.map { max(0, $0) } }
    }

    /// Limits the tokens each user's bots on the plan may use in a period; nil lets them use any number.
    /// It applies straight away, to tokens already used in the period too.
    public func setTokenLimit(_ limit: HubTokenLimit?, in plan: HubPlan) {
        guard let current = plans.first(where: { $0.id == plan.id }), current.tokenLimit != limit else { return }
        update(plan) { $0.tokenLimit = limit }
        onTokenLimitsChange?()
    }

    /// Users on a deleted plan go back to Default.
    public func delete(_ plan: HubPlan) {
        guard !plan.isDefault, let plan = plans.first(where: { $0.id == plan.id }) else { return }
        plans.removeAll { $0.id == plan.id }
        let defaultName = plans.first(where: \.isDefault)?.name ?? "Default"
        for index in users.indices where users[index].plan == plan.id {
            users[index].plan = HubPlan.defaultID
            note("Moved \(users[index].name) to the \(defaultName) plan, as the \(plan.name) plan was deleted", about: [users[index].id])
        }
        save()
        onTokenLimitsChange?()
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

    /// Pictures of people, kept beside the file every check-in rewrites rather than in it.
    private var picturesURL: URL { url.deletingLastPathComponent().appendingPathComponent("People", isDirectory: true) }

    private func pictureURL(of user: UUID) -> URL { picturesURL.appendingPathComponent(user.uuidString) }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Stored(users: users, plans: plans, devices: devices, botOwners: botOwners, botHosts: botHosts,
                                                         connectionOwners: connectionOwners, computerOwners: computerOwners,
                                                         browserOwners: browserOwners)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Only the Hub reads it: it holds the grants devices gave to ring them and the keys for who is calling.
        try? AtomicFile.write(data, to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
