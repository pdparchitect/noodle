import HubLink
import SwiftUI
import UIKit

@main
struct NoodleMobileApp: App {
    @State private var hubs = HubMemberships(
        directory: URL.applicationSupportDirectory.appendingPathComponent("Hubs", isDirectory: true),
        deviceName: UIDevice.current.name)

    var body: some Scene {
        WindowGroup {
            Group {
                if let pairing = hubs.hubs.first {
                    AgentsView(pairing: pairing)
                } else {
                    JoinView()
                }
            }
            .environment(hubs)
            // An invitation link opened from Messages, Mail or a QR code in the Camera app.
            .onOpenURL { url in Task { await hubs.join(url.absoluteString) } }
            .task { await hubs.stayConnected() }
        }
    }
}
