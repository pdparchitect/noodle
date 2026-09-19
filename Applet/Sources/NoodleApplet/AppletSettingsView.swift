import AppKit
import SwiftUI
import NoodleSettingsUI

enum AppletSettingsTab: Hashable { case general, permissions, updates }

struct AppletSettingsView: View {
    @ObservedObject var background: AppletBackgroundStore
    @ObservedObject var library: AppletLibrary
    @State private var selection: AppletSettingsTab = .general
    @ObservedObject private var updater = AppletUpdater.shared

    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
            AppletGeneralSettingsView(background: background)
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AppletSettingsTab.general)
            AppletPermissionsSettingsView(library: library)
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
                .tag(AppletSettingsTab.permissions)
            AppletUpdatesSettingsView()
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(AppletSettingsTab.updates)
        }
        .modifier(AppletSettingsResizeAnchor())
        .settingsScrollIndicators(selection: selection)
        .background(SettingsTabBadge(counts: ["Update": updater.availableVersion == nil ? 0 : 1]))
        // Check on opening Settings so the tab is badged before it is selected.
        .onAppear { updater.probeForUpdate() }
    }
}

private struct AppletGeneralSettingsView: View {
    @ObservedObject var background: AppletBackgroundStore
    @State private var changingBackground = false

    var body: some View {
        Form {
            CompanionVisibilitySettings()
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

private struct AppletPermissionsSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @State private var grants: [String: [String]] = [:]

    private func title(_ key: String) -> String {
        library.entries.first { $0.package.key == key }?.package.manifest.title ?? "Removed Noodlet"
    }
    var body: some View {
        Form {
            Section {
                if grants.isEmpty {
                    Text("No noodlets have permissions.").foregroundStyle(.secondary)
                }
                ForEach(grants.keys.sorted { title($0) < title($1) }, id: \.self) { key in
                    LabeledContent {
                        Button("Remove") {
                            AppletPermissions.revoke(packageKey: key, defaults: .standard)
                            grants = AppletPermissions.grants(defaults: .standard)
                        }
                    } label: {
                        Text(title(key))
                        Text((grants[key] ?? []).compactMap { AppletPermissions.titles[$0] }.joined(separator: ", "))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { grants = AppletPermissions.grants(defaults: .standard) }
    }
}

private struct AppletSettingsResizeAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.windowResizeAnchor(.top) } else { content }
    }
}
