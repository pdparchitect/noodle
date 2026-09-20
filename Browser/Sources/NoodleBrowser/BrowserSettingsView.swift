import AppKit
import NoodleSettingsUI
import SwiftUI

enum BrowserSettingsTab: Hashable { case general, updates }

struct BrowserSettingsView: View {
    @State private var selection: BrowserSettingsTab
    @ObservedObject private var updater = BrowserUpdater.shared
    init(selection: BrowserSettingsTab = .general) { _selection = State(initialValue: selection) }
    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
            BrowserGeneralSettingsView()
                .frame(width: 580).fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(BrowserSettingsTab.general)
            BrowserUpdatesSettingsView()
                .frame(width: 580).fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }.tag(BrowserSettingsTab.updates)
        }
        .windowResizeAnchor(.top)
        .settingsScrollIndicators(selection: selection)
        .background(SettingsTabBadge(counts: ["Update": updater.availableVersion == nil ? 0 : 1]))
        // Check on opening Settings so the tab is badged before it is selected.
        .onAppear { updater.probeForUpdate() }
    }
}
private struct BrowserGeneralSettingsView: View {
    @AppStorage("BrowserRestoreSelection") private var restoreSelection = true
    @AppStorage("BrowserSearchEngine") private var searchEngine = "duckduckgo"
    var body: some View {
        Form {
            CompanionVisibilitySettings()
            Section {
                Toggle("Restore selected browser on launch", isOn: $restoreSelection)
                Picker("Search engine", selection: $searchEngine) {
                    Text("DuckDuckGo").tag("duckduckgo"); Text("Google").tag("google"); Text("Bing").tag("bing")
                }
            }
        }.formStyle(.grouped)
    }
}
struct BrowserUpdatesSettingsView: View {
    @ObservedObject private var updater = BrowserUpdater.shared
    var body: some View {
        Form {
            Section {
                LabeledContent("Installed Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                }
                if let version = updater.availableVersion {
                    Text("Update available — \(version)").font(.caption).foregroundStyle(.orange)
                }
                UpdateSettingsButton(availableVersion: updater.availableVersion, canCheck: updater.canCheck, action: updater.check)
            }
            Section {
                Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
                    .disabled(!updater.enabled)
                Toggle("Automatically download and install updates", isOn: Binding(get: { updater.automaticallyDownloads }, set: updater.setAutomaticDownloads))
                    .disabled(!updater.allowsAutomaticUpdates)
            }
        }.formStyle(.grouped).onAppear { updater.start() }
    }
}
