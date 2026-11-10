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
    /// What the organisation fixed one of Sparkle's automatic settings to: both off while it leaves updates to its MDM,
    /// since Sparkle checks by itself only while its own setting is on; nothing may veto Sparkle itself.
    func fixedValue(of setting: OrganisationSetting) -> Bool? {
        updatesAllowed ? OrganisationStatus.shared.value(of: setting) : false
    }
    /// The organisation fixed whether Sparkle checks, or downloads and installs, by itself.
    var checksAreManaged: Bool { fixedValue(of: .automaticUpdateChecks) != nil }
    var downloadsAreManaged: Bool { fixedValue(of: .automaticUpdateInstalls) != nil }

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
           updatesAllowed, controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// What one of Sparkle's settings becomes, and what is kept of the person's own: a fixed value replaces it
    /// and keeps theirs aside, once; without one, theirs comes back.
    static func settle(current: Bool, fixed: Bool?, kept: Bool?) -> (value: Bool, kept: Bool?) {
        if let fixed { return (fixed, kept ?? current) }
        return (kept ?? current, nil)
    }

    private static let keptChecksKey = "Noodle.updates.personsAutomaticChecks"
    private static let keptDownloadsKey = "Noodle.updates.personsAutomaticDownloads"

    /// Sets Sparkle's own settings to what the organisation fixed, and puts the person's back once it no longer
    /// does.
    private func applyOrganisationPolicy() {
        objectWillChange.send()
        let updater = controller.updater
        let checks = settle(updater.automaticallyChecksForUpdates, fixed: fixedValue(of: .automaticUpdateChecks),
                            key: Self.keptChecksKey)
        let downloads = settle(updater.automaticallyDownloadsUpdates, fixed: fixedValue(of: .automaticUpdateInstalls),
                               key: Self.keptDownloadsKey)
        if updater.automaticallyChecksForUpdates != checks { updater.automaticallyChecksForUpdates = checks }
        if updater.automaticallyDownloadsUpdates != downloads { updater.automaticallyDownloadsUpdates = downloads }
    }

    private func settle(_ current: Bool, fixed: Bool?, key: String) -> Bool {
        let defaults = UserDefaults.standard
        let settled = Self.settle(current: current, fixed: fixed, kept: defaults.object(forKey: key) as? Bool)
        if let kept = settled.kept { defaults.set(kept, forKey: key) } else { defaults.removeObject(forKey: key) }
        return settled.value
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
                                                fixed: updater.fixedValue(of: .automaticUpdateChecks)) },
                    set: updater.setAutomaticChecks
                ))
                .disabled(updater.checksAreManaged)
                .help(updater.checksAreManaged ? Organisation.managedText : "")
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { AppUpdater.effective(person: updater.automaticallyDownloads,
                                                fixed: updater.fixedValue(of: .automaticUpdateInstalls)) },
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
