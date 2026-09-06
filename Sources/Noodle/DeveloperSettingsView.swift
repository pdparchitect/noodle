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
            } footer: {
                Text("Checks whether extended access is available.")
            }
        }
        .formStyle(.grouped)
    }
}
#endif
