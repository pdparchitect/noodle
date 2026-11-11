import Foundation
import ProductIdentity

@MainActor
public final class AgentActivitySleepController {
    private var activity: NSObjectProtocol?

    /// Only a Mac sleeps while bots work; a server stays up on its own.
    func update(shouldPreventIdleSleep: Bool) {
        #if canImport(Darwin)
        if shouldPreventIdleSleep, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "\(ProductIdentity.current.name) agents are working"
            )
        } else if !shouldPreventIdleSleep, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }

    deinit {
        #if canImport(Darwin)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        #endif
    }
}
