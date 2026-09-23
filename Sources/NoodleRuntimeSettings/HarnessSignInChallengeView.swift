import AppKit
import SwiftUI
import NoodleCore

/// The device code a harness asks the user to enter on its own sign-in page.
public struct HarnessSignInChallengeView: View {
    let challenge: HarnessSignInChallenge
    @Environment(\.openURL) private var openURL

    public var body: some View {
        HStack {
            Text(challenge.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Button("Copy Code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(challenge.code, forType: .string)
            }
            Button("Open Sign-In Page") { openURL(challenge.url) }
        }
        Text("Enter this code on the sign-in page.")
            .font(.caption).foregroundStyle(.secondary)
    }

    public init(challenge: HarnessSignInChallenge) {
        self.challenge = challenge
    }
}
