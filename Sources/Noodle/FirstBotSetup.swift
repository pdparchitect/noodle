import AppKit
import Foundation
import Observation
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import SwiftUI

/// The first-run flow: choose a harness, get it ready, name the bot. It owns
/// only the order of those steps; installing, signing in and creating the bot
/// are the same operations Settings and New Bot use.
@MainActor @Observable
final class FirstBotSetup {
    enum Step { case harness, prepare, team }
    enum Readiness: Equatable { case checking, ready, signIn, install, unavailable }

    static let dismissedKey = "Noodle.firstBotSetup.dismissed"

    /// Noodle's accounts offered for a quick start; every other harness is set up in Settings.
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

    /// Beneath a tile's name: who makes it, or that it runs on this Mac.
    static func subtitle(_ provider: HarnessProvider) -> String? {
        if let maker = maker(provider) { return "by \(maker)" }
        return provider == .apple ? "on this Mac" : nil
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
    /// The accounts this app offers, in order.
    let accounts: [HarnessProvider]

    /// Without `accounts`, Noodle's.
    init(setup: HarnessSetupController, runtime: AgentRuntimeCoordinator, accounts: [HarnessProvider]? = nil) {
        self.setup = setup
        self.runtime = runtime
        self.accounts = accounts ?? Self.featured
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
            if let match = accounts.first(where: { readiness($0) == wanted }) { return match }
        }
        return accounts.first ?? .codex
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

/// The welcome's steps, in every app: choose an account, get it ready, meet the team it made. The app says which
/// accounts, how its bots look, what their roles are, how the team is made, and what comes before the accounts.
struct FirstBotSetupSteps<Leading: View>: View {
    let setup: HarnessSetupController
    let runtime: AgentRuntimeCoordinator
    /// Makes the team on the account, or returns nil for someone who already has bots, which ends the welcome.
    /// An empty team means it could not be made and the reason was shown; the person can try again.
    let makeTeam: (HarnessProvider) -> (team: [AgentRecord], groupID: UUID?)?
    let introduce: (UUID) -> Void
    let finish: () -> Void
    let picture: (AgentRecord) -> AnyView
    let roles: [String]
    var columnWidth: CGFloat = 140
    @ViewBuilder let leadingTile: () -> Leading
    @State private var steps: FirstBotSetup
    /// The bots made once the account is ready, shown for a moment before the group opens.
    @State private var team: [AgentRecord] = []
    @State private var groupID: UUID?

    init(setup: HarnessSetupController, runtime: AgentRuntimeCoordinator, accounts: [HarnessProvider]? = nil,
         makeTeam: @escaping (HarnessProvider) -> (team: [AgentRecord], groupID: UUID?)?, introduce: @escaping (UUID) -> Void,
         finish: @escaping () -> Void, picture: @escaping (AgentRecord) -> AnyView, roles: [String], columnWidth: CGFloat = 140,
         @ViewBuilder leadingTile: @escaping () -> Leading) {
        self.setup = setup
        self.runtime = runtime
        self.makeTeam = makeTeam
        self.introduce = introduce
        self.finish = finish
        self.picture = picture
        self.roles = roles
        self.columnWidth = columnWidth
        self.leadingTile = leadingTile
        _steps = State(initialValue: FirstBotSetup(setup: setup, runtime: runtime, accounts: accounts))
    }

    private var id: HarnessProvider { steps.selection }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                switch steps.step {
                case .harness: harnessStep
                // Its actions follow the step's progress, so they read as links beside it.
                case .prepare: prepareStep.buttonStyle(.accentLink)
                case .team: teamStep
                }
                if steps.step == .prepare { navigation }
            }
            .padding(20)
        }
        .frame(width: 640)
        .task { await setup.refreshAll(runtime) }
        .onChange(of: steps.readiness(id)) { _, _ in steps.advanceIfReady() }
        // A download reports the sign-in it needs before it stops being busy.
        .onChange(of: steps.isBusy) { _, _ in steps.advanceIfReady() }
        .onChange(of: steps.step) { _, step in
            guard step == .team else { return }
            // Someone with bots came back through Help > Welcome to set up an account, and is done.
            guard let made = makeTeam(id) else { return finish() }
            // Nothing was made, and the reason is already shown; let the person try again.
            guard !made.team.isEmpty else { steps.back(); return }
            team = made.team
            groupID = made.groupID
        }
    }

    /// Choosing an account moves on by itself; what is left is trying again after a stop, and the way back.
    private var navigation: some View {
        HStack {
            if setup.activity[id] == nil, setup.challenges[id] == nil {
                switch steps.readiness(id) {
                case .install: Button("Install") { steps.install() }
                case .signIn: Button("Sign In…") { steps.signIn() }
                case .checking, .ready, .unavailable: EmptyView()
                }
            }
            Spacer()
            Button("Back") { steps.back() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.accentLink)
    }

    private var harnessStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                leadingTile()
                ForEach(steps.accounts) { tile(for: $0) }
            }
            Button("Not Now", action: finish)
                .buttonStyle(.accentLink)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(for provider: HarnessProvider) -> some View {
        Button { steps.choose(provider) } label: {
            VStack(spacing: 8) {
                HarnessProviderIcon(provider: provider)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(name(provider)).font(.headline)
                    if let subtitle = FirstBotSetup.subtitle(provider) {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                status(for: provider)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(![.install, .signIn, .ready].contains(steps.readiness(provider)))
        .accessibilityLabel(FirstBotSetup.maker(provider).map { "\(name(provider)) by \($0)" } ?? name(provider))
    }

    private func name(_ provider: HarnessProvider) -> String {
        FirstBotSetup.accountName(provider) ?? provider.displayName
    }

    /// The download is part of signing in, so a harness that is not installed asks for sign-in too.
    private func status(for provider: HarnessProvider) -> SettingsStatusLabel {
        switch steps.readiness(provider) {
        case .checking: SettingsStatusLabel(title: "Checking…", systemImage: "ellipsis.circle", color: .secondary)
        case .ready: SettingsStatusLabel(title: "Ready", systemImage: "checkmark.circle.fill", color: .green)
        case .signIn, .install: SettingsStatusLabel(title: "Sign-in required", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)
        case .unavailable: SettingsStatusLabel(title: "Unavailable", systemImage: "minus.circle", color: .secondary)
        }
    }

    @ViewBuilder private var prepareStep: some View {
        HStack(spacing: 12) {
            HarnessProviderIcon(provider: id)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(name(id)).fontWeight(.semibold)
            Spacer()
            status(for: id)
        }
        if let activity = setup.activity[id] {
            VStack(alignment: .leading, spacing: 6) {
                // One bar throughout, so nothing moves: it fills for a download of known size and
                // runs indeterminate otherwise, as while waiting for sign-in.
                ProgressView(value: setup.installProgress[id])
                    .progressViewStyle(.linear)
                Text(activity).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let challenge = setup.challenges[id] {
            HarnessSignInChallengeView(challenge: challenge)
        }
        if let command = setup.terminalSignIns[id] {
            HarnessTerminalSignInView(command: command) {
                Task { await setup.refreshAll(runtime) }
            }
        }
        if let error = setup.errors[id] {
            Text(error).font(.caption).foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var teamStep: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(team.enumerated()), id: \.element.id) { index, bot in
                    VStack(spacing: 6) {
                        picture(bot)
                        Text(bot.displayName).font(.headline).multilineTextAlignment(.center)
                        if index < roles.count {
                            Text(roles[index]).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    // Equal columns, so the middle one sits under the title whatever the roles say.
                    .frame(width: columnWidth)
                    .accessibilityElement(children: .combine)
                }
            }
            Button("Continue") {
                if let groupID { introduce(groupID) }
                finish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }
}

extension FirstBotSetupSteps where Leading == EmptyView {
    init(setup: HarnessSetupController, runtime: AgentRuntimeCoordinator, accounts: [HarnessProvider]? = nil,
         makeTeam: @escaping (HarnessProvider) -> (team: [AgentRecord], groupID: UUID?)?, introduce: @escaping (UUID) -> Void,
         finish: @escaping () -> Void, picture: @escaping (AgentRecord) -> AnyView, roles: [String], columnWidth: CGFloat = 140) {
        self.init(setup: setup, runtime: runtime, accounts: accounts, makeTeam: makeTeam, introduce: introduce, finish: finish,
                  picture: picture, roles: roles, columnWidth: columnWidth) { EmptyView() }
    }
}

/// While the welcome shows, the window's close button asks first, and closing counts as Not Now.
/// It borrows the button's action rather than the window's delegate, which SwiftUI owns.
struct WelcomeCloseGuard: NSViewRepresentable {
    let leave: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window, leave: leave) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.leave = leave }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject {
        var leave: @MainActor () -> Void = {}
        private weak var button: NSButton?
        private weak var originalTarget: AnyObject?
        private var originalAction: Selector?

        func attach(to window: NSWindow?, leave: @escaping @MainActor () -> Void) {
            guard button == nil, let button = window?.standardWindowButton(.closeButton) else { return }
            self.leave = leave
            self.button = button
            originalTarget = button.target
            originalAction = button.action
            button.target = self
            button.action = #selector(confirmClose(_:))
        }

        func detach() {
            guard let button else { return }
            button.target = originalTarget
            button.action = originalAction
            self.button = nil
        }

        @objc private func confirmClose(_ sender: NSButton) {
            guard let window = sender.window else { return }
            let alert = NSAlert()
            alert.messageText = "Leave the welcome?"
            alert.informativeText = "You can come back to it from Help > Welcome."
            alert.addButton(withTitle: "Leave")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                self.detach()
                self.leave()
                window.performClose(nil)
            }
        }
    }
}
