import Combine
import Sparkle
import SwiftUI

/// Sparkle updates for released builds. Local builds leave it off.
@MainActor final class HubUpdater: NSObject, ObservableObject {
    static let shared = HubUpdater()
    @Published private(set) var canCheck = false
    var enabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NoodleUpdatesEnabled") as? Bool == true
    }
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    func start() {
        guard !started, enabled else { return }
        started = true
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.startUpdater()
    }

    func check() { if started { controller.checkForUpdates(nil) } }
}

struct HubCheckForUpdatesButton: View {
    @ObservedObject private var updater = HubUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
    }
}
