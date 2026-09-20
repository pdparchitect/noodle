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
        availableVersion == nil ? "Check for Updates…" : "Install Update…"
    }
}
