import AppKit
import Combine
import NoodleSettingsUI
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    /// The newer version Sparkle last found, from any check. Skipped versions are not found.
    @Published private(set) var availableVersion: String?
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        // Sparkle owns installation and relaunch. Agent and editor state must not
        // veto the user's Install and Relaunch request. The delegate only observes.
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )

    func start() {
        guard !started,
              Bundle.main.object(forInfoDictionaryKey: "NoodleUpdatesEnabled") as? Bool == true else { return }
        started = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        if started { controller.checkForUpdates(nil) }
    }

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

extension AppUpdater: SPUUpdaterDelegate {
    // Sparkle calls its delegate on the main thread.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

struct UpdatesSettingsView: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                }
                if let version = updater.availableVersion {
                    Text("Update available — \(version)").font(.caption).foregroundStyle(.orange)
                }
                UpdateSettingsButton(availableVersion: updater.availableVersion, canCheck: updater.canCheckForUpdates,
                                     action: updater.checkForUpdates)
            }
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks
                ))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: updater.setAutomaticDownloads
                ))
                .disabled(!updater.allowsAutomaticUpdates)
            }
        }
        .formStyle(.grouped)
    }
}
