import AppKit
import Combine
import Sparkle
import SwiftUI
import NoodleSettingsUI

@MainActor final class BrowserUpdater: NSObject, ObservableObject {
    static let shared = BrowserUpdater()
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

extension BrowserUpdater: SPUUpdaterDelegate {
    // Sparkle calls its delegate on the main thread.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}

struct BrowserCheckForUpdatesButton: View {
    @ObservedObject private var updater = BrowserUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
}
