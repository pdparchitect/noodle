import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var isWaitingToRelaunch = false
    private(set) var isInstallingUpdate = false
    private var started = false
    private var deferredRelaunch: Task<Void, Never>?
    private lazy var controller = SPUStandardUpdaterController(
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

    func setAutomaticChecks(_ enabled: Bool) {
        if started { controller.updater.automaticallyChecksForUpdates = enabled }
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        if started { controller.updater.automaticallyDownloadsUpdates = enabled }
    }

    var canRelaunch: Bool { NoodleStore.active?.canRelaunchForUpdate ?? false }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstallingUpdate = true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard !canRelaunch else { return false }
        isWaitingToRelaunch = true
        deferredRelaunch?.cancel()
        deferredRelaunch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                if self.canRelaunch {
                    self.isWaitingToRelaunch = false
                    self.deferredRelaunch = nil
                    installHandler()
                    return
                }
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        deferredRelaunch?.cancel()
        deferredRelaunch = nil
        isWaitingToRelaunch = false
        isInstallingUpdate = false
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
            if updater.isWaitingToRelaunch {
                Label("Update ready. Waiting for agents or unsaved changes…", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
