import NoodleRuntime
import NoodleRuntimeSettings
import SwiftUI

struct UsageMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    let history: UsageHistory

    var body: some View {
        Button {
            history.agentFilter = nil
            openWindow(id: UsageView.windowID)
        } label: {
            Label("Usage", systemImage: "chart.bar")
                .labelStyle(.titleAndIcon)
        }
        .appShortcut(.showUsage)
    }
}

/// Reads the bots from the store so the picker follows renames and new bots.
struct NoodleUsageView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        UsageView(history: store.usage, agents: store.agents)
    }
}
