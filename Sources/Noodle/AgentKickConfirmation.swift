import SwiftUI
import NoodleCore
import NoodleRuntime

/// Attach to the containing view so closing a context menu cannot dismiss the alert.
struct AgentKickConfirmation: ViewModifier {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Binding var request: AgentKickRequest?

    func body(content: Content) -> some View {
        content.alert(request?.title ?? "Recover Bot", isPresented: Binding(
            get: { request != nil }, set: { if !$0 { request = nil } }
        ), presenting: request) { request in
            if request.failure == .authenticationRequired {
                Button("Open Harness Settings") {
                    store.selectedSettingsTab = .harnesses
                    openSettings()
                }
            }
            Button(recoveryButtonTitle(request)) {
                store.runtime.confirmKick(request, repository: store.repository)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }

    private func recoveryButtonTitle(_ request: AgentKickRequest) -> String {
        if case .missingSession = request.failure { return "Recover Bot" }
        return "Retry Now"
    }
}
