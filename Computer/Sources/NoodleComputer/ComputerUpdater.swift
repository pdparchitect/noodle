import AppKit
import Combine
import Sparkle
import SwiftUI

@MainActor final class ComputerUpdater: ObservableObject {
    static let shared = ComputerUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    func start() {
        guard !started, Bundle.main.object(forInfoDictionaryKey: "NoodleUpdatesEnabled") as? Bool == true else { return }
        started = true
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        controller.startUpdater()
    }
    func check() { if started { controller.checkForUpdates(nil) } }
    func setAutomaticChecks(_ enabled: Bool) {
        if started { controller.updater.automaticallyChecksForUpdates = enabled }
    }
}

struct ComputerUpdateCommands: View {
    @ObservedObject private var updater = ComputerUpdater.shared
    var body: some View {
        Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck)
        Toggle("Automatically Check for Updates", isOn: Binding(
            get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
            .disabled(Bundle.main.object(forInfoDictionaryKey: "NoodleUpdatesEnabled") as? Bool != true)
    }
}
