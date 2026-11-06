import Foundation
import ProductIdentity

@MainActor
public final class AgentActivitySleepController {
    private var activity: NSObjectProtocol?

    func update(shouldPreventIdleSleep: Bool) {
        if shouldPreventIdleSleep, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "\(ProductIdentity.current.name) agents are working"
            )
        } else if !shouldPreventIdleSleep, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    deinit {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
