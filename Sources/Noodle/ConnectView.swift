import SwiftUI
import NoodleBrand
import NoodleWallpaper

/// Help > Connect, in the main window as the welcome is: reaching this Mac from other devices,
/// or sharing harnesses with other people, which takes Noodle Hub.
struct ConnectView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var sharing = false

    private static let hubDownload = URL(string: "https://github.com/pdparchitect/noodle/releases/download/hub-latest/Noodle-Hub-arm64.dmg")!

    var body: some View {
        WordmarkWelcome(centred: true, continuesItself: true) {
            VStack(spacing: 16) {
                if sharing { sharingStep } else { choiceStep }
            }
            .padding(20)
            .frame(width: 640)
        }
        .background {
            ConversationWallpaper(background: store.background(for: nil))
                .ignoresSafeArea()
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                .sharedBackgroundVisibility(.hidden)
        }
    }

    private var choiceStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                tile("Connect to This Mac", detail: "Use Noodle from your other devices", systemImage: "laptopcomputer.and.iphone") {
                    store.connectThisMac()
                    openSettings()
                }
                tile("Share With Others", detail: "Let other people use your harnesses", systemImage: "person.2") {
                    withAnimation { sharing = true }
                }
            }
            Button("Not Now") { store.showsConnect = false }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var sharingStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Sharing needs Noodle Hub").font(.headline)
            Text("Install Noodle Hub on an always-on Mac. Other people's bots run there, with your sign-ins kept on the Hub.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Link("Download Noodle Hub", destination: Self.hubDownload)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Back") { withAnimation { sharing = false } }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tile(_ title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
