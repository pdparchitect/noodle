import HubLink
import SwiftUI
import UIKit

@main
struct NoodleMobileApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var phase
    @State private var notifications = HubNotifications()
    @State private var hubs: HubMemberships

    init() {
        let shared = AppGroup.hubs ?? URL.applicationSupportDirectory.appendingPathComponent("Hubs", isDirectory: true)
        _hubs = State(initialValue: HubMemberships(directory: shared, deviceName: UIDevice.current.name))
        // Pulling to refresh writes the wordmark instead of turning the spinner.
        UIRefreshControl.appearance().tintColor = .clear
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hubs.hubs.isEmpty {
                    JoinView()
                } else {
                    AgentsView(pairings: hubs.hubs, opening: Binding(get: { delegate.opening }, set: { delegate.opening = $0 }))
                }
            }
            .environment(hubs)
            // An invitation link opened from Messages, Mail or a QR code in the Camera app.
            .onOpenURL { url in hubs.offer(url.absoluteString) }
            .alert("Join this Hub?", isPresented: Binding(get: { hubs.offered != nil }, set: { if !$0 { hubs.declineOffered() } }),
                   presenting: hubs.offered) { invitation in
                Button("Cancel", role: .cancel) {}
                Button("Join") { Task { await hubs.join(invitation.url().absoluteString) } }
            } message: { invitation in
                Text("Hub key \(invitation.hubKey.fingerprint)")
            }
            .task { await hubs.stayConnected() }
            // Again each time the app comes back, since notifications may have been turned off or on in Settings.
            .task(id: NotificationKey(hubs: hubs.hubs.map(CurrentHub.name), active: phase == .active)) {
                guard phase == .active else { return }
                // Nobody is asked until there is a Hub to hear from.
                let allowed = hubs.hubs.isEmpty ? true : await HubNotifications.allowed(registering: delegate)
                await notifications.register(hubs.hubs, allowed: allowed)
            }
        }
    }
}

private struct NotificationKey: Equatable {
    let hubs: [String]
    let active: Bool
}

/// A joined Hub, named on the phone by its folder.
@MainActor enum CurrentHub {
    static func name(of pairing: HubPairing) -> String { pairing.directory.lastPathComponent }

    /// Its space, by the Hub's key, so the choice is kept when the Hub is left and joined again.
    static func space(of pairing: HubPairing) -> String { pairing.hub?.key.x963.base64EncodedString() ?? name(of: pairing) }
}
