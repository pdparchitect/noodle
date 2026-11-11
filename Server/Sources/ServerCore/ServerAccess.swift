import Foundation
import HubCore
import NoodleCore

/// The YAML file is what the server's plans and users are: starting makes the Hub's records match it.
/// Records are matched by name, so a user keeps their devices and bots across restarts. A user left
/// out of the file is suspended, keeping their data; a plan left out is deleted, its users moving to
/// Default as on any Hub.
@MainActor public enum ServerAccess {
    public static func apply(_ configuration: ServerConfiguration, to access: HubAccess) throws {
        for plan in configuration.plans {
            let record = try access.plans.first { matches($0, plan.name) } ?? access.addPlan(named: plan.name)
            let wanted = Set(plan.harnesses.map { HubHarness(provider: $0, profile: nil) })
            for harness in record.harnesses where !wanted.contains(harness) { access.set(harness, included: false, in: record) }
            for harness in wanted where !record.harnesses.contains(harness) { access.set(harness, included: true, in: record) }
            for harness in wanted {
                access.setModels(plan.models[harness.provider].map(Set.init), for: harness, in: record)
            }
            access.setTokenLimit(plan.tokens, in: record)
        }
        for record in access.plans where !record.isDefault && !configuration.plans.contains(where: { matches(record, $0.name) }) {
            access.delete(record)
        }

        for user in configuration.users {
            guard let plan = access.plans.first(where: { matches($0, user.plan) }) else {
                throw ServerConfigurationError("users.\(user.name).plan: there is no plan named \(user.plan).")
            }
            let record = try access.users.first { $0.name == user.name } ?? access.addUser(named: user.name)
            access.move(record, to: plan)
            access.setAdmin(user.isAdmin, for: record)
            access.setCanPairDevices(user.canPairDevices, for: record)
            access.setSuspended(false, for: record)
        }
        for record in access.users where !configuration.users.contains(where: { $0.name == record.name }) {
            access.setSuspended(true, for: record)
        }
    }

    /// The Default plan answers to its own name whatever it was renamed to on a Hub.
    private static func matches(_ plan: HubPlan, _ name: String) -> Bool {
        plan.name == name || (plan.isDefault && name == ServerConfiguration.defaultPlan)
    }
}
