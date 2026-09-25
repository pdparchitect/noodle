import HubLink
import SwiftUI
import UIKit

@main
struct NoodleMobileApp: App {
    @State private var hubs = HubMemberships(
        directory: URL.applicationSupportDirectory.appendingPathComponent("Hubs", isDirectory: true),
        deviceName: UIDevice.current.name)
    @AppStorage(CurrentHub.key) private var current = ""
    @AppStorage(CurrentHub.togetherKey) private var together = false

    var body: some Scene {
        WindowGroup {
            Group {
                let shown = CurrentHub.shown(hubs.hubs, saved: current, together: together)
                if shown.isEmpty {
                    JoinView()
                } else {
                    AgentsView(pairings: shown)
                }
            }
            .environment(hubs)
            // An invitation link opened from Messages, Mail or a QR code in the Camera app.
            .onOpenURL { url in Task { await hubs.join(url.absoluteString) } }
            .onChange(of: hubs.hubs.map(CurrentHub.name)) { before, after in
                if let joined = CurrentHub.joined(before: before, after: after) { current = joined }
            }
            .task { await hubs.stayConnected() }
        }
    }
}

/// The Hub the phone shows, of those it joined; saved on the phone by the name of the Hub's folder.
@MainActor enum CurrentHub {
    static let key = "currentHub"
    /// Whether every Hub's bots show in one list, rather than one Hub's at a time.
    static let togetherKey = "hubsTogether"

    static func name(of pairing: HubPairing) -> String { pairing.directory.lastPathComponent }

    static func pick(_ hubs: [HubPairing], saved: String) -> HubPairing? {
        hubs.first { name(of: $0) == saved } ?? hubs.first
    }

    static func shown(_ hubs: [HubPairing], saved: String, together: Bool) -> [HubPairing] {
        together ? hubs : pick(hubs, saved: saved).map { [$0] } ?? []
    }

    /// A Hub just joined, which the phone then shows.
    static func joined(before: [String], after: [String]) -> String? {
        after.first { !before.contains($0) }
    }
}
