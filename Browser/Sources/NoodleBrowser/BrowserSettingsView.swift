import AppKit
import BrowserBridge
import BrowserCore
import BrowserExternal
import NoodleExternalToolsUI
import NoodleSettingsUI
import SwiftUI

enum BrowserSettingsTab: Hashable { case general, external, updates }

struct BrowserSettingsView: View {
    @State private var selection: BrowserSettingsTab
    @ObservedObject private var updater = BrowserUpdater.shared
    @ObservedObject private var library: BrowserLibrary
    private let runtime: BrowserRuntime
    init(library: BrowserLibrary, runtime: BrowserRuntime, selection: BrowserSettingsTab = .general) {
        self.library = library; self.runtime = runtime; _selection = State(initialValue: selection)
    }
    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
            BrowserGeneralSettingsView()
                .frame(width: 580).fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(BrowserSettingsTab.general)
            if let external = runtime.external {
                ExternalToolsSettingsView(gate: external, noun: "browser",
                    items: library.profiles.filter { $0.hub != true }.map { ExternalItem(id: $0.id, name: $0.name, symbol: $0.symbol) },
                    command: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/noodle-browser").path,
                    server: BrowserBuildIdentity.current == .development ? "noodle-browser-dev" : "noodle-browser",
                    delete: { ids in Task { for id in ids { try? await runtime.removeBrowser(id) } } })
                    .frame(width: 580).fixedSize(horizontal: false, vertical: true)
                    .tabItem { Label("External Tools", systemImage: "point.3.connected.trianglepath.dotted") }.tag(BrowserSettingsTab.external)
            }
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
    @AppStorage("BrowserTabExpiryDays") private var tabExpiryDays = 7
    var body: some View {
        Form {
            CompanionVisibilitySettings()
            Section {
                Toggle("Restore selected browser on launch", isOn: $restoreSelection)
                Picker("Search engine", selection: $searchEngine) {
                    Text("DuckDuckGo").tag("duckduckgo"); Text("Google").tag("google"); Text("Bing").tag("bing")
                }
                Picker("Close tabs not used for", selection: $tabExpiryDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("Never").tag(0)
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
