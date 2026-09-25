import NoodleCore
import NoodleRuntimeSettings

extension NoodleStore {
    func showActivity(for agent: AgentRecord) {
        activityWindows.show(agent: agent, log: runtime.activity.log(for: agent.id))
    }
}
