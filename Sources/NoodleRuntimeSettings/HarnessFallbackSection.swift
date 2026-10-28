import SwiftUI
import NoodleCore
import NoodleRuntime

/// Settings › Harnesses: where every bot continues, in order, when its harness runs out of usage.
struct HarnessFallbackSection: View {
    let store: any BotSettingsHost

    private var runtime: AgentRuntimeCoordinator { store.runtime }

    private var harnesses: HarnessSelection { runtime.harnesses }

    private func choices(_ provider: HarnessProvider) -> [HarnessFallbackTarget] {
        [HarnessFallbackTarget(provider: provider)] + store.harnessProfiles.profiles(for: provider).map {
            HarnessFallbackTarget(provider: provider, profile: $0.id)
        }
    }

    private var addable: [HarnessProvider] {
        HarnessProvider.allCases.filter { provider in
            harnesses.isOn(provider) && choices(provider).contains { !harnesses.fallbackTargets.contains($0) }
        }
    }

    private func profileName(_ target: HarnessFallbackTarget) -> String {
        guard let id = target.profile else { return "Default" }
        return store.harnessProfiles.profile(id)?.displayName ?? "Unavailable Profile"
    }

    private func add(_ target: HarnessFallbackTarget) {
        harnesses.setFallbackTargets(harnesses.fallbackTargets + [target])
    }

    var body: some View {
        Section {
            Toggle("Use the fallback list when usage runs out", isOn: Binding(
                get: { harnesses.fallbackIsOn }, set: { harnesses.setFallback(on: $0) }))
                .help("After trying eligible profiles on the current harness, continue on the next available profile or harness in this list. Switching harnesses uses the new harness’s default model. The bot returns to its saved login when usage is available again.")
            if harnesses.fallbackIsOn {
                ForEach(Array(harnesses.fallbackTargets.enumerated()), id: \.element) { index, target in
                    row(target, at: index)
                }
                HStack {
                    Menu("Add Harness") {
                        ForEach(addable, id: \.self) { provider in
                            if provider.supportsProfiles {
                                Menu(provider.displayName) {
                                    ForEach(choices(provider).filter { !harnesses.fallbackTargets.contains($0) }, id: \.self) { target in
                                        Button(profileName(target)) { add(target) }
                                    }
                                }
                            } else {
                                Button(provider.displayName) { add(HarnessFallbackTarget(provider: provider)) }
                            }
                        }
                    }
                    .fixedSize()
                    .disabled(addable.isEmpty)
                    Spacer()
                }
            }
        }
    }

    private func row(_ target: HarnessFallbackTarget, at index: Int) -> some View {
        let provider = target.provider
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            Text(provider.displayName)
            if provider.supportsProfiles {
                Text(profileName(target)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            status(target)
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                if provider.supportsProfiles {
                    Menu("Profile") {
                        ForEach(choices(provider).filter { $0 == target || !harnesses.fallbackTargets.contains($0) }, id: \.self) { choice in
                            Toggle(profileName(choice), isOn: Binding(get: { choice == target }, set: { selected in
                                guard selected else { return }
                                var list = harnesses.fallbackTargets
                                list[index] = choice
                                harnesses.setFallbackTargets(list)
                            }))
                        }
                    }
                    Divider()
                }
                Button("Move Up") { move(index, by: -1) }
                    .disabled(index == 0)
                Button("Move Down") { move(index, by: 1) }
                    .disabled(index == harnesses.fallbackTargets.count - 1)
                Divider()
                Button("Remove", role: .destructive) {
                    harnesses.setFallbackTargets(harnesses.fallbackTargets.filter { $0 != target })
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(provider.displayName)\(provider.supportsProfiles ? " · " + profileName(target) : "") Actions")
        }
    }

    @ViewBuilder private func status(_ target: HarnessFallbackTarget) -> some View {
        let provider = target.provider
        if !harnesses.isOn(provider) {
            Text("Turned off")
        } else if !runtime.installations.contains(where: { $0.provider == provider && $0.isAvailable }) {
            Text("Not installed")
        } else if let id = target.profile, store.harnessProfiles.profile(id) == nil {
            Text("Profile unavailable")
        } else if let date = runtime.usageReturns(provider, profile: target.profile) {
            Text("Out of usage until \(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var list = harnesses.fallbackTargets
        guard list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        harnesses.setFallbackTargets(list)
    }
}
