import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        // Sparkle owns installation and relaunch. Agent and editor state must not
        // veto the user's Install and Relaunch request.
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
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

    func setAutomaticChecks(_ enabled: Bool) {
        if started { controller.updater.automaticallyChecksForUpdates = enabled }
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        if started { controller.updater.automaticallyDownloadsUpdates = enabled }
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
                CheckForUpdatesButton()
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
