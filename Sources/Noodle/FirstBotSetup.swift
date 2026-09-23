import Foundation
import Observation
import NoodleCore
import NoodleRuntime

/// The first-run flow: choose a harness, get it ready, name the bot. It owns
/// only the order of those steps; installing, signing in and creating the bot
/// are the same operations Settings and New Bot use.
@MainActor @Observable
final class FirstBotSetup {
    enum Step { case harness, prepare, bot }
    enum Readiness: Equatable { case checking, ready, signIn, install, unavailable }

    static let dismissedKey = "Noodle.firstBotSetup.dismissed"

    /// The vendors offered as tiles; every other harness waits under Other.
    static let featured: [HarnessProvider] = [.codex, .claudeCode, .muse, .grokBuild]
    static let others = HarnessProvider.allCases.filter { !featured.contains($0) }

    private(set) var step = Step.harness
    /// The user's own choice; until then the best candidate is shown selected.
    var chosen: HarnessProvider?
    /// Other opened by hand; it also opens on its own to show a selection it holds.
    var othersRevealed = false
    private let setup: HarnessSetupController
    private let runtime: AgentRuntimeCoordinator

    init(setup: HarnessSetupController, runtime: AgentRuntimeCoordinator) {
        self.setup = setup
        self.runtime = runtime
    }

    var selection: HarnessProvider { chosen ?? preferred }

    var showsOthers: Bool { othersRevealed || Self.others.contains(selection) }

    func installation(_ id: HarnessProvider) -> HarnessInstallation? {
        runtime.installations.first { $0.provider == id && $0.isAvailable }
    }

    func readiness(_ id: HarnessProvider) -> Readiness {
        guard installation(id) != nil else { return setup.canInstall(id) ? .install : .unavailable }
        // Apple's harness is always present; its on-device model may not be.
        if id == .apple, runtime.capabilityErrors[.apple] != nil { return .unavailable }
        switch setup.authentication[id] {
        case .authenticated, .notRequired: return .ready
        case .unauthenticated, .managedExternally: return .signIn
        case nil: return setup.errors[id] == nil ? .checking : .signIn
        }
    }

    /// Whatever needs the least from the user, leaving the experimental harness for last.
    var preferred: HarnessProvider {
        let order = HarnessProvider.allCases.filter { !$0.isExperimental } + HarnessProvider.allCases.filter(\.isExperimental)
        for wanted in [Readiness.ready, .signIn, .checking, .install] {
            if let match = order.first(where: { readiness($0) == wanted }) { return match }
        }
        return .codex
    }

    var canContinue: Bool {
        switch step {
        case .harness: return readiness(selection) != .unavailable && readiness(selection) != .checking
        case .prepare: return false
        case .bot: return true
        }
    }

    var isBusy: Bool { setup.activity[selection] != nil }

    func proceed() {
        guard step == .harness, canContinue else { return }
        chosen = selection
        if readiness(selection) == .ready { step = .bot; return }
        step = .prepare
        // Choosing a harness that is not installed is the request to install it.
        if readiness(selection) == .install { install() }
    }

    func back() {
        guard step != .harness else { return }
        setup.cancel(selection)
        step = .harness
    }

    func install() { setup.install(selection, runtime: runtime) }

    func signIn() {
        guard let installation = installation(selection) else { return }
        setup.signIn(installation)
    }

    /// Called as the harness's state changes while it is being prepared.
    func advanceIfReady() {
        if step == .prepare, readiness(selection) == .ready { step = .bot }
    }
}
