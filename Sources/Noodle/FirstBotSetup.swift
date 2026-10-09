import Foundation
import Observation
import NoodleCore
import NoodleRuntime

/// The first-run flow: choose a harness, get it ready, name the bot. It owns
/// only the order of those steps; installing, signing in and creating the bot
/// are the same operations Settings and New Bot use.
@MainActor @Observable
final class FirstBotSetup {
    enum Step { case harness, prepare, team }
    enum Readiness: Equatable { case checking, ready, signIn, install, unavailable }

    static let dismissedKey = "Noodle.firstBotSetup.dismissed"

    /// The accounts offered for a quick start; every other harness is set up in Settings.
    static let featured = HarnessProvider.allCases.filter(\.isOnByDefault)

    /// A tile names the product by its short name, with its maker beneath.
    static func accountName(_ provider: HarnessProvider) -> String? {
        switch provider {
        case .codex: "Codex"
        case .claudeCode: "Claude"
        case .muse: "Muse"
        case .grokBuild: "Grok"
        case .fx, .openCode, .antigravity, .apple: nil
        }
    }

    static func maker(_ provider: HarnessProvider) -> String? {
        switch provider {
        case .codex: "OpenAI"
        case .claudeCode: "Anthropic"
        case .muse: "Meta"
        case .grokBuild: "xAI"
        case .fx, .openCode, .antigravity, .apple: nil
        }
    }

    private(set) var step = Step.harness
    /// The user's own choice; until then the best candidate is shown selected.
    var chosen: HarnessProvider?
    /// Sign-in opens on its own once each time a harness is prepared. After that it waits
    /// for Sign In, so a browser page the person closed does not open again.
    private var signInStarted = false
    private let setup: HarnessSetupController
    private let runtime: AgentRuntimeCoordinator

    init(setup: HarnessSetupController, runtime: AgentRuntimeCoordinator) {
        self.setup = setup
        self.runtime = runtime
    }

    var selection: HarnessProvider { chosen ?? preferred }

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
        // Unknown and not being looked at, as after a failed check or a cancelled sign-in, it needs a sign-in.
        case nil: return setup.checking.contains(id) ? .checking : .signIn
        }
    }

    /// Whatever needs the least from the user.
    var preferred: HarnessProvider {
        for wanted in [Readiness.ready, .signIn, .checking, .install] {
            if let match = Self.featured.first(where: { readiness($0) == wanted }) { return match }
        }
        return .codex
    }

    var canContinue: Bool {
        switch step {
        case .harness: return readiness(selection) != .unavailable && readiness(selection) != .checking
        case .prepare: return false
        case .team: return true
        }
    }

    var isBusy: Bool { setup.activity[selection] != nil }

    func proceed() {
        guard step == .harness, canContinue else { return }
        chosen = selection
        if readiness(selection) == .ready { step = .team; return }
        step = .prepare
        signInStarted = false
        // Choosing a harness is the request to install it and sign in.
        switch readiness(selection) {
        case .install: install()
        case .signIn: startSignIn()
        case .checking, .ready, .unavailable: break
        }
    }

    /// Choosing an account is the request to set it up.
    func choose(_ provider: HarnessProvider) {
        guard step == .harness else { return }
        chosen = provider
        proceed()
    }

    /// Stops whatever is under way and returns to the accounts.
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
        guard step == .prepare else { return }
        switch readiness(selection) {
        case .ready: step = .team
        case .signIn where !isBusy && !signInStarted: startSignIn()
        case .signIn, .checking, .install, .unavailable: break
        }
    }

    private func startSignIn() {
        signInStarted = true
        signIn()
    }
}
