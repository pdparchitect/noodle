import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import PionCore
import SwiftUI

/// The main window's sheets and panels, which menu commands open too.
@MainActor @Observable final class WindowState {
    enum Sheet: Identifiable {
        case newInvestigation, newGroup, newAgent, editAgent(AgentRecord), editGroup(BotConversation), editInvestigation(Investigation), close(Investigation)
        var id: String {
            switch self {
            case .newInvestigation: "new-investigation"
            case .newGroup: "new-group"
            case .newAgent: "new-agent"
            case .editAgent(let agent): "edit-agent-\(agent.id)"
            case .editGroup(let group): "edit-group-\(group.id)"
            case .editInvestigation(let investigation): "edit-investigation-\(investigation.id)"
            case .close(let investigation): "close-\(investigation.id)"
            }
        }
    }

    enum InspectorTab: String, CaseIterable { case caseRecord = "Case", audit = "Audit Log" }

    func edit(_ conversation: BotConversation, in model: PionModel) {
        switch conversation.kind {
        case .direct:
            if let agent = model.agent(conversation.participantIDs.first) { sheet = .editAgent(agent) }
        case .group:
            if let investigation = model.investigation(conversation.id) {
                if !investigation.isClosed { sheet = .editInvestigation(investigation) }
            } else { sheet = .editGroup(conversation) }
        }
    }

    /// Reply, from an agent's profile in a group, as in Noodle: addresses it in the message field, which takes the
    /// keyboard. Nil outside a group, or where nothing can be sent.
    func reply(to agent: AgentRecord, in conversation: BotConversation?, model: PionModel) -> (() -> Void)? {
        guard let conversation, conversation.kind == .group, model.investigation(conversation.id)?.isClosed != true,
              model.composerUnavailableReason(for: conversation) == nil else { return nil }
        return { [weak self] in
            model.reply(to: agent, in: conversation.id)
            self?.composerFocusRequest = UUID()
        }
    }

    var sheet: Sheet?
    /// The tool whose page is shown where a conversation would be, picked in the sidebar; picking a conversation clears it.
    var selectedTool: UUID?
    var showsInspector = true
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

