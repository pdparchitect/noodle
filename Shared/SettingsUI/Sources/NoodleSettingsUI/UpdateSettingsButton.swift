import SwiftUI

/// The update button on a Settings Update tab. Sparkle's user-initiated check
/// offers the update it finds, so one action serves both titles.
public struct UpdateSettingsButton: View {
    let availableVersion: String?
    let canCheck: Bool
    let action: () -> Void

    public init(availableVersion: String?, canCheck: Bool, action: @escaping () -> Void) {
        self.availableVersion = availableVersion
        self.canCheck = canCheck
        self.action = action
    }

    public var body: some View {
        Button(Self.title(availableVersion: availableVersion), action: action).disabled(!canCheck)
    }

    static func title(availableVersion: String?) -> String {
        availableVersion == nil ? "Check for Updates" : "Install Update…"
    }
}

/// Sparkle looks for updates once a day. An old version reaches the latest one through each migration
/// milestone in turn, so without looking again straight after each step it would rest a day on every milestone.
public enum UpdateFollowUp {
    static let key = "NoodleLastLaunchedVersion"

    /// Records the version launched and says whether it differs from the one launched before, as it does
    /// right after an update. The first launch, and a build without a version, never count.
    public static func justUpdated(to version: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let version else { return false }
        let last = defaults.string(forKey: key)
        defaults.set(version, forKey: key)
        return last.map { $0 != version } ?? false
    }
}
