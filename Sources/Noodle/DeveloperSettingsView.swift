#if DEBUG
import SwiftUI

struct DeveloperSettingsView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        Form {
            Section {
                Button(store.runtime.isCheckingAccess ? "Checking…" : "Test Extended Runtime") {
                    store.runtime.checkExtendedRuntime()
                }
                .disabled(store.runtime.isCheckingAccess)
                if let result = store.runtime.accessCheckResult {
                    Text(result).font(.caption).textSelection(.enabled)
                }
            } header: {
                Text("Runtime Diagnostics")
            } footer: {
                Text("This checks helper isolation compatibility only, not bot startup or browser access. It does not enable a bot or send a message.")
            }
            Text("Development build only. This entire tab is excluded from release builds.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
#endif
