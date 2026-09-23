import AppKit
import SwiftUI
import NoodleCore
import NoodleSettingsUI
import NoodleRuntime

public struct HeartbeatsSettingsView: View {
    let store: any BotSettingsHost
    @State private var showsHeartbeatInfo = false
    private let heartbeatColumnWidth: CGFloat = 64

    private static let suggestedIntervals = [5, 10, 15, 30, 45, 60, 120, 240, 480, 720, 1_440]

    private var intervalOptions: [Int] {
        let current = store.runtime.heartbeatConfiguration.intervalMinutes
        return Array(Set(Self.suggestedIntervals + [current])).sorted()
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Wake idle agents", isOn: Binding(
                    get: { store.runtime.heartbeatConfiguration.isEnabled },
                    set: { store.runtime.configureHeartbeats(enabled: $0) }
                ))
                Picker("Wake after", selection: Binding(
                    get: { store.runtime.heartbeatConfiguration.intervalMinutes },
                    set: { store.runtime.configureHeartbeats(intervalMinutes: $0) }
                )) {
                    ForEach(intervalOptions, id: \.self) { minutes in
                        Text(intervalLabel(for: minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!store.runtime.heartbeatConfiguration.isEnabled)
            }
            if !store.agents.isEmpty {
                Section {
                    SettingsBotList(agents: store.agents) { agent in
                        HStack(spacing: 12) {
                            store.botProfileButton(agent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.displayName)
                                if let date = store.runtime.lastHeartbeatDates[agent.id] {
                                    HStack(spacing: 0) {
                                        Text("Last heartbeat ")
                                        Text(date, style: .relative)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("No heartbeat yet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("Heartbeat for \(agent.displayName)", isOn: Binding(
                                get: { !store.runtime.heartbeatConfiguration.disabledAgentIDs.contains(agent.id) },
                                set: { store.runtime.setHeartbeatEnabled($0, for: agent.id) }
                            ))
                            .labelsHidden()
                            .controlSize(.mini)
                            .disabled(!store.runtime.heartbeatConfiguration.isEnabled)
                            .frame(width: heartbeatColumnWidth)
                        }
                    }
                } header: {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Heartbeat") { showsHeartbeatInfo.toggle() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About heartbeats")
                            .help("About heartbeats")
                            .frame(width: heartbeatColumnWidth)
                            .popover(isPresented: $showsHeartbeatInfo) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Heartbeat").font(.headline)
                                    Text("Allows this bot to wake after the selected period of inactivity to check for work. Heartbeats run only while the bot is idle.")
                                    Text("Wake idle agents must also be on. Turning this bot's switch off stops its automatic heartbeats; it can still respond to messages.")
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(20)
                                .frame(width: 360, alignment: .leading)
                            }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func intervalLabel(for minutes: Int) -> String {
        switch minutes {
        case 60:
            "1 hour"
        case 1_440:
            "1 day"
        case let value where value.isMultiple(of: 60):
            "\(value / 60) hours"
        case 1:
            "1 minute"
        default:
            "\(minutes) minutes"
        }
    }

    public init(store: any BotSettingsHost) {
        self.store = store
    }
}
