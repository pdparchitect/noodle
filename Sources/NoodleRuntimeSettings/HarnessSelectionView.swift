import SwiftUI
import NoodleCore
import NoodleSettingsUI
import NoodleRuntime

/// Turns harnesses on and off; one that is off leaves the Harness tab and every picker.
/// Choices apply when the sheet closes, so the Settings window does not resize under it.
struct HarnessSelectionView: View {
    let runtime: AgentRuntimeCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var turnedOn: Set<HarnessProvider>

    init(runtime: AgentRuntimeCoordinator) {
        self.runtime = runtime
        _turnedOn = State(initialValue: Set(HarnessProvider.allCases.filter(runtime.harnesses.isOn)))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Harnesses").font(.title2.bold())
                VStack(spacing: 12) {
                    ForEach(HarnessProvider.allCases) { provider in
                        Toggle(isOn: Binding(get: { turnedOn.contains(provider) },
                                             set: { if $0 { turnedOn.insert(provider) } else { turnedOn.remove(provider) } })) {
                            HStack(spacing: 10) {
                                HarnessProviderIcon(provider: provider)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .accessibilityHidden(true)
                                Text(provider.displayName)
                                if provider.isExperimental {
                                    Text("Experimental").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.switch)
                    }
                }
            }
            .padding(24)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear {
            for provider in HarnessProvider.allCases { runtime.setHarness(provider, on: turnedOn.contains(provider)) }
        }
    }
}
