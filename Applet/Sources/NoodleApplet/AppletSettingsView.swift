import AppKit
import SwiftUI

enum AppletSettingsTab: Hashable { case general, updates }

struct AppletSettingsView: View {
    @ObservedObject var background: AppletBackgroundStore
    @State private var selection: AppletSettingsTab = .general

    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
            AppletGeneralSettingsView(background: background)
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AppletSettingsTab.general)
            AppletUpdatesSettingsView()
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(AppletSettingsTab.updates)
        }
        .modifier(AppletSettingsResizeAnchor())
    }
}

private struct AppletGeneralSettingsView: View {
    @ObservedObject var background: AppletBackgroundStore
    @AppStorage("showMenuBar") private var showMenuBar = false
    @State private var changingBackground = false

    var body: some View {
        Form {
            Section {
                Toggle("Show recent noodlets in the menu bar", isOn: $showMenuBar)
            }
            Section {
                LabeledContent("Library background") {
                    Button("Change Background…") { changingBackground = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingBackground) {
            AppletBackgroundSheet(store: background)
        }
    }
}

private struct AppletSettingsResizeAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.windowResizeAnchor(.top) } else { content }
    }
}
