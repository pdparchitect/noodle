import HubWire
import NoodleBrand
import NoodleCore
import NoodleRuntime
import SwiftUI

/// Settings › General: how new bots are named, how groups notify, whether the Mac stays awake while they
/// work, and the organisation's policies when there are any.
public struct RuntimeGeneralSettings: View {
    let member: String
    let groupNotifications: Binding<LinkNotifications>
    let runtime: AgentRuntimeCoordinator
    @AppStorage private var nameStyle: String

    /// `member` names what the app calls a bot; the name style is kept under `nameStyleKey`.
    public init(member: String, nameStyleKey: String, defaultNameStyle: BotNameStyle,
                groupNotifications: Binding<LinkNotifications>, runtime: AgentRuntimeCoordinator) {
        self.member = member
        self.groupNotifications = groupNotifications
        self.runtime = runtime
        _nameStyle = AppStorage(wrappedValue: defaultNameStyle.rawValue, nameStyleKey)
    }

    public var body: some View {
        Form {
            Section {
                Picker("Generated \(member) names", selection: $nameStyle) {
                    ForEach(BotNameStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("In groups, notify me for", selection: groupNotifications) {
                    Text("All messages").tag(LinkNotifications.all)
                    Text("Only when my name is mentioned").tag(LinkNotifications.mentions)
                }
                .help("Your name is your full name, or your first name alone. One-to-one chats always notify, and a group can have its own setting in its menu in the sidebar.")
            }
            Section {
                Toggle("Keep Mac awake while agents work", isOn: Binding(
                    get: { runtime.preventIdleSleepWhileWorking },
                    set: { runtime.configurePreventIdleSleepWhileWorking($0) }
                ))
            } footer: {
                Text("Prevents automatic idle sleep only while an agent is working. Closing the lid or choosing Sleep still suspends the Mac.")
            }
            // Only on a Mac whose organisation set policies with a configuration profile.
            OrganisationPoliciesSection()
        }
        .formStyle(.grouped)
    }
}

public extension BotSettingsHost {
    /// Harnesses whose row asks for attention, or whose bots failed and can be kicked: the Harness tab's badge.
    func harnessesNeedingAttention(_ setup: HarnessSetupController) -> Int {
        HarnessProvider.allCases.filter { id in
            runtime.harnesses.isOn(id) && (setup.needsAttention(id) || agents.contains {
                let snapshot = runtime.snapshot(for: $0.id)
                return $0.harnessIdentifier == id.rawValue && snapshot.canKick && snapshot.phase == .failed
            })
        }.count
    }

    /// Tools whose row shows Needs attention: the Tools tab's badge.
    var toolsNeedingAttention: Int {
        connectionsController.registry.connections.filter { connectionsController.errors[$0.id] != nil }.count
    }
}
