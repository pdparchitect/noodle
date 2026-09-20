import AppKit
import Combine
import Sparkle
import SwiftUI
import NoodleSettingsUI

@MainActor final class ComputerUpdater: NSObject, ObservableObject {
    static let shared = ComputerUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    /// The newer version Sparkle last found, from any check. Skipped versions are not found.
    @Published private(set) var availableVersion: String?
    var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "NoodleUpdatesEnabled") as? Bool == true }
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        guard !started, enabled else { return }
        started = true
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        controller.updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        controller.startUpdater()
    }
    func check() { if started { controller.checkForUpdates(nil) } }
    /// Asks Sparkle whether an update exists without offering it.
    func probeForUpdate() {
        if started, controller.updater.canCheckForUpdates { controller.updater.checkForUpdateInformation() }
    }
    func setAutomaticChecks(_ enabled: Bool) {
        if started { controller.updater.automaticallyChecksForUpdates = enabled }
    }
    func setAutomaticDownloads(_ enabled: Bool) {
        if started { controller.updater.automaticallyDownloadsUpdates = enabled }
    }
}

extension ComputerUpdater: SPUUpdaterDelegate {
    // Sparkle calls its delegate on the main thread.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}

struct ComputerCheckForUpdatesButton: View {
    @ObservedObject private var updater = ComputerUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
}

enum ComputerSettingsTab: Hashable { case general, storage, updates }

struct ComputerSettingsView: View {
    @State private var selection: ComputerSettingsTab = .general
    @ObservedObject private var updater = ComputerUpdater.shared
    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
            ComputerGeneralSettingsView()
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(ComputerSettingsTab.general)
            StorageSettingsView()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(ComputerSettingsTab.storage)
            ComputerUpdatesSettingsView()
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(ComputerSettingsTab.updates)
        }
        .windowResizeAnchor(.top)
        .settingsScrollIndicators(selection: selection)
        .background(SettingsTabBadge(counts: ["Update": updater.availableVersion == nil ? 0 : 1]))
        // Check on opening Settings so the tab is badged before it is selected.
        .onAppear { updater.probeForUpdate() }
    }
}

struct ComputerGeneralSettingsView: View {
    @AppStorage("StartNewComputersAutomatically") private var startNewComputersAutomatically = true

    var body: some View {
        Form {
            CompanionVisibilitySettings()
            Section {
                Toggle("Start new computers automatically", isOn: $startNewComputersAutomatically)
            }
        }
        .formStyle(.grouped)
    }
}

struct ComputerUpdatesSettingsView: View {
    @ObservedObject private var updater = ComputerUpdater.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                }
                if let version = updater.availableVersion {
                    Text("Update available — \(version)").font(.caption).foregroundStyle(.orange)
                }
                UpdateSettingsButton(availableVersion: updater.availableVersion, canCheck: updater.canCheck,
                                     action: updater.check)
            }
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks
                ))
                .disabled(!updater.enabled)
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: updater.setAutomaticDownloads
                ))
                .disabled(!updater.allowsAutomaticUpdates)
            }
        }
        .formStyle(.grouped)
        .onAppear { updater.start() }
    }
}
