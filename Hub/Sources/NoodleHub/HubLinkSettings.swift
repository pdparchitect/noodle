import AppKit
import HubCore
import HubLink
import NoodleRuntimeSettings
import ServiceManagement
import SwiftUI

/// Whether devices can reach the Hub, and the addresses invitations carry.
struct HubNetworkSettingsView: View {
    @Bindable var link: HubLinkService
    @State private var opensAtLogin = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section {
                HubLinkRows(link: link, statusTitle: "Status") {
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        LabeledContent("Connected") {
                            let people = link.connectedUsers.count, devices = link.connectedDevices.count
                            Text(devices == 0 ? "No one"
                                 : "\(people) \(people == 1 ? "person" : "people") on \(devices) \(devices == 1 ? "device" : "devices")")
                        }
                    }
                    Toggle("Open at Login", isOn: Binding(
                        get: { opensAtLogin == .enabled || opensAtLogin == .requiresApproval },
                        set: { setOpensAtLogin($0) }))
                        .help("Opens the Hub in the menu bar when you log in, so devices can reach it after the Mac restarts")
                    if opensAtLogin == .requiresApproval {
                        LabeledContent("Needs approval in Login Items") {
                            Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Login Items can be changed in System Settings while this is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            opensAtLogin = SMAppService.mainApp.status
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Noodle Hub could not change Open at Login: \(error.localizedDescription)")
        }
        opensAtLogin = SMAppService.mainApp.status
    }
}
