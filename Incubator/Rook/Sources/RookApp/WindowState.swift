import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import RookCore
import SwiftUI

/// The main window's sheets and panels, which menu commands open too.
@MainActor @Observable final class WindowState {
    enum Sheet: Identifiable {
        case newMission, newGroup, newAgent, editAgent(AgentRecord), editGroup(BotConversation), editMission(Mission), close(Mission)
        var id: String {
            switch self {
            case .newMission: "new-mission"
            case .newGroup: "new-group"
            case .newAgent: "new-agent"
            case .editAgent(let agent): "edit-agent-\(agent.id)"
            case .editGroup(let group): "edit-group-\(group.id)"
            case .editMission(let mission): "edit-mission-\(mission.id)"
            case .close(let mission): "close-\(mission.id)"
            }
        }
    }

    enum InspectorTab: String, CaseIterable { case caseRecord = "Case", audit = "Audit Log" }

    func edit(_ conversation: BotConversation, in model: RookModel) {
        switch conversation.kind {
        case .direct:
            if let agent = model.agent(conversation.participantIDs.first) { sheet = .editAgent(agent) }
        case .group:
            if let mission = model.mission(conversation.id) {
                if !mission.isClosed { sheet = .editMission(mission) }
            } else { sheet = .editGroup(conversation) }
        }
    }

    /// Reply, from an agent's profile in a group, as in Noodle: addresses it in the message field, which takes the
    /// keyboard. Nil outside a group, or where nothing can be sent.
    func reply(to agent: AgentRecord, in conversation: BotConversation?, model: RookModel) -> (() -> Void)? {
        guard let conversation, conversation.kind == .group, model.mission(conversation.id)?.isClosed != true,
              model.composerUnavailableReason(for: conversation) == nil else { return nil }
        return { [weak self] in
            model.reply(to: agent, in: conversation.id)
            self?.composerFocusRequest = UUID()
        }
    }

    var sheet: Sheet?
    var showsInspector = true
    /// The attack-graph overlay for the selected Mission; ephemeral, so leaving the Mission closes it.
    var showsGraph = false
    var inspectorTab: InspectorTab = .caseRecord
    /// Asks the composer of the selected conversation to take the keyboard.
    var composerFocusRequest = UUID()
    /// Set when the sidebar's selection moved with the arrow keys, which leaves the keyboard in the list, as in Noodle.
    @ObservationIgnored var selectedFromKeyboard = false
    var searchText = ""
    /// What was said that the sidebar's search is for, found as in Noodle.
    let mentions = MentionFinder()
    /// The main window's; Shift-Tab in the message field goes back to its sidebar, as in Noodle.
    var hasSidebar = false
    var sidebarFocusRequest: UUID?
    var searchFocusRequest = UUID()
    /// Kick's question, and the agent whose New Session is being confirmed, as in Noodle.
    var kickRequest: AgentKickRequest?
    var newSessionAgent: AgentRecord?
    /// Opens the main window, or brings it forward, for a notification clicked while it is closed.
    @ObservationIgnored var openMain: (() -> Void)?
}

