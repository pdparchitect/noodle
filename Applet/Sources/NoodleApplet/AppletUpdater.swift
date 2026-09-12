import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor final class AppletUpdater: ObservableObject {
    static let shared = AppletUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    var enabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NoodleUpdatesEnabled") as? Bool == true
    }
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    func start() {
        guard !started, enabled else { return }
        started = true
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(
            to: &$automaticallyChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).assign(
            to: &$automaticallyDownloads)
        controller.updater.publisher(for: \.allowsAutomaticUpdates).assign(
            to: &$allowsAutomaticUpdates)
        controller.startUpdater()
    }
    func check() { if started { controller.checkForUpdates(nil) } }
    func setAutomaticChecks(_ enabled: Bool) {
        if started { controller.updater.automaticallyChecksForUpdates = enabled }
    }
    func setAutomaticDownloads(_ enabled: Bool) {
        if started { controller.updater.automaticallyDownloadsUpdates = enabled }
    }
}

struct AppletCheckForUpdatesButton: View {
    @ObservedObject private var updater = AppletUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
}

struct AppletUpdatesSettingsView: View {
    @ObservedObject private var updater = AppletUpdater.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed Version") {
                    Text(
                        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                            as? String ?? "Development")
                }
                AppletCheckForUpdatesButton()
            }
            Section {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks
                    )
                )
                .disabled(!updater.enabled)
                Toggle(
                    "Automatically download and install updates",
                    isOn: Binding(
                        get: { updater.automaticallyDownloads }, set: updater.setAutomaticDownloads
                    )
                )
                .disabled(!updater.allowsAutomaticUpdates)
            }
        }
        .formStyle(.grouped)
        .onAppear { updater.start() }
    }
}
