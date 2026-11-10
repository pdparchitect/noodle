import AppKit
import Combine
import NoodleCore
import NoodleSettingsUI
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    @Published private var sparkleCanCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var allowsAutomaticUpdates = false
    /// The newer version Sparkle last found, from any check. Skipped versions are not found.
    @Published private(set) var availableVersion: String?
    private var started = false
    private var policyObserver: NSObjectProtocol?
    private lazy var controller = SPUStandardUpdaterController(
        // Sparkle owns installation and relaunch. Agent and editor state must not
        // veto the user's Install and Relaunch request. The delegate only observes.
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
    )

    /// Whether the organisation lets Noodle update itself; one that leaves updates to its MDM doesn't.
    var updatesAllowed: Bool { OrganisationStatus.shared.allows(.updates) }
    var canCheckForUpdates: Bool { sparkleCanCheck && updatesAllowed }
    /// The organisation fixed whether Sparkle checks, or downloads and installs, by itself.
    var checksAreManaged: Bool { OrganisationStatus.shared.value(of: .automaticUpdateChecks) != nil || !updatesAllowed }
    var downloadsAreManaged: Bool { OrganisationStatus.shared.value(of: .automaticUpdateInstalls) != nil || !updatesAllowed }

    /// The organisation's fixed value wins over the person's own.
    static func effective(person: Bool, fixed: Bool?) -> Bool { fixed ?? person }

    func start() {
        guard !started,
              Bundle.main.object(forInfoDictionaryKey: "NoodleUpdatesEnabled") as? Bool == true else { return }
        started = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$sparkleCanCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.allowsAutomaticUpdates).assign(to: &$allowsAutomaticUpdates)
        applyOrganisationPolicy()
        policyObserver = NotificationCenter.default.addObserver(forName: Organisation.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyOrganisationPolicy() }
        }
        controller.startUpdater()
        // Straight after an update, as through each migration milestone, the next step is looked for at once.
        if UpdateFollowUp.justUpdated(to: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
           controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// Sets Sparkle's own settings to what the organisation fixed. Sparkle keeps them, so removing the profile
    /// leaves them as they were last fixed until the person changes them.
    private func applyOrganisationPolicy() {
        objectWillChange.send()
        let updater = controller.updater
        let checks = updatesAllowed ? OrganisationStatus.shared.value(of: .automaticUpdateChecks) : false
        let downloads = updatesAllowed ? OrganisationStatus.shared.value(of: .automaticUpdateInstalls) : false
        if let checks, updater.automaticallyChecksForUpdates != checks { updater.automaticallyChecksForUpdates = checks }
        if let downloads, updater.automaticallyDownloadsUpdates != downloads { updater.automaticallyDownloadsUpdates = downloads }
    }

    func checkForUpdates() {
        if started, updatesAllowed { controller.checkForUpdates(nil) }
    }

    /// Asks Sparkle whether an update exists without offering it.
    func probeForUpdate() {
        if started, updatesAllowed, controller.updater.canCheckForUpdates { controller.updater.checkForUpdateInformation() }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        if started, !checksAreManaged { controller.updater.automaticallyChecksForUpdates = enabled }
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        if started, !downloadsAreManaged { controller.updater.automaticallyDownloadsUpdates = enabled }
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

    /// Where every check, scheduled or chosen, asks first: none while the organisation leaves updates to its MDM.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let allowed = MainActor.assumeIsolated { updatesAllowed }
        guard allowed else {
            throw NSError(domain: "NoodleUpdates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Your organisation manages updates to Noodle."])
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates") { updater.checkForUpdates() }
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
                if let version = updater.availableVersion, updater.updatesAllowed {
                    Text("Update available — \(version)").font(.caption).foregroundStyle(.orange)
                }
                UpdateSettingsButton(availableVersion: updater.updatesAllowed ? updater.availableVersion : nil,
                                     canCheck: updater.canCheckForUpdates, action: updater.checkForUpdates)
            } footer: {
                if !updater.updatesAllowed { Text(Organisation.managedText) }
            }
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { AppUpdater.effective(person: updater.automaticallyChecks,
                                                fixed: updater.updatesAllowed ? OrganisationStatus.shared.value(of: .automaticUpdateChecks) : false) },
                    set: updater.setAutomaticChecks
                ))
                .disabled(updater.checksAreManaged)
                .help(updater.checksAreManaged ? Organisation.managedText : "")
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { AppUpdater.effective(person: updater.automaticallyDownloads,
                                                fixed: updater.updatesAllowed ? OrganisationStatus.shared.value(of: .automaticUpdateInstalls) : false) },
                    set: updater.setAutomaticDownloads
                ))
                .disabled(!updater.allowsAutomaticUpdates || updater.downloadsAreManaged)
                .help(updater.downloadsAreManaged ? Organisation.managedText : "")
            } footer: {
                if updater.updatesAllowed, updater.checksAreManaged || updater.downloadsAreManaged { Text(Organisation.managedText) }
            }
        }
        .formStyle(.grouped)
    }
}
