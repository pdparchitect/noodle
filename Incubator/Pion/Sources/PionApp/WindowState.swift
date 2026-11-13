import NoodleCore
import PionCore
import SwiftUI

/// The main window's sheets and panels, which menu commands open too.
@MainActor @Observable final class WindowState {
    enum Sheet: Identifiable {
        case newInvestigation, newGroup, newAgent, chooseConversation, editAgent(AgentRecord), editGroup(BotConversation), editInvestigation(Investigation), close(Investigation)
        var id: String {
            switch self {
            case .newInvestigation: "new-investigation"
            case .newGroup: "new-group"
            case .newAgent: "new-agent"
            case .chooseConversation: "choose-conversation"
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

    var sheet: Sheet?
    var showsInspector = true
    var inspectorTab: InspectorTab = .caseRecord
    /// Asks the composer of the selected conversation to take the keyboard.
    var composerFocusRequest = UUID()
    var searchText = ""
    var searchFocusRequest = UUID()
    var floatsOnTop = false
}

