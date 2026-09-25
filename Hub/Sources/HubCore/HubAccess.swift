import Foundation
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

/// The Hub's users and plans, kept in one file beside its bots.
@MainActor @Observable public final class HubAccess {
    public private(set) var users: [HubUser] = []
    public private(set) var plans: [HubPlan] = []
    @ObservationIgnored private let url: URL

    private struct Stored: Codable {
        var users: [HubUser]
        var plans: [HubPlan]
    }

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            users = stored.users
            plans = stored.plans
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

    public func remove(_ user: HubUser) {
        users.removeAll { $0.id == user.id }
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
        guard let data = try? encoder.encode(Stored(users: users, plans: plans)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? AtomicFile.write(data, to: url)
    }
}
