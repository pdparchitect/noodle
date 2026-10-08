import SwiftUI
import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings

/// The steps the welcome brings up under the wordmark.
struct FirstBotSetupSheet: View {
    @Environment(NoodleStore.self) private var store
    @AppStorage(BotNameStyle.defaultsKey) private var botNameStyle = BotNameStyle.real.rawValue
    @State private var model: FirstBotSetup
    /// The bots made once the account is ready, shown for a moment before the group opens.
    @State private var team: [AgentRecord] = []
    @State private var teamGroupID: UUID?

    init(setup: HarnessSetupController, runtime: AgentRuntimeCoordinator) {
        _model = State(initialValue: FirstBotSetup(setup: setup, runtime: runtime))
    }

    private var setup: HarnessSetupController { store.harnessSetup }
    private var id: HarnessProvider { model.selection }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                switch model.step {
                case .harness: harnessStep
                // Its actions follow the step's progress, so they read as links beside it.
                case .prepare: prepareStep.buttonStyle(.link)
                case .team: teamStep
                }
                if model.step == .prepare { navigation }
            }
            .padding(20)
        }
        .frame(width: 640)
        .task { await setup.refreshAll(store.runtime) }
        .onChange(of: model.readiness(id)) { _, _ in model.advanceIfReady() }
        // A download reports the sign-in it needs before it stops being busy.
        .onChange(of: model.isBusy) { _, _ in model.advanceIfReady() }
        .onChange(of: model.step) { _, step in
            guard step == .team else { return }
            // Someone with bots came back through Help > Welcome to set up an account, and is done.
            guard let made = store.createStarterTeamIfFirst(on: id, style: nameStyle) else {
                store.finishFirstBotSetup()
                return
            }
            team = made
            // Nothing was made, and the reason is already shown; let the person try again.
            guard !team.isEmpty else { model.back(); return }
            teamGroupID = store.selectedConversation?.kind == .group ? store.selectedConversationID : nil
        }
    }

    /// Choosing an account moves on by itself; what is left is trying again after a stop, and the way back.
    private var navigation: some View {
        HStack {
            if setup.activity[id] == nil, setup.challenges[id] == nil {
                switch model.readiness(id) {
                case .install: Button("Install") { model.install() }
                case .signIn: Button("Sign In…") { model.signIn() }
                case .checking, .ready, .unavailable: EmptyView()
                }
            }
            Spacer()
            Button("Back") { model.back() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.link)
    }

    private var harnessStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ForEach(FirstBotSetup.featured) { provider in
                    tile(for: provider)
                }
            }
            Button("Not Now") { store.finishFirstBotSetup() }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func tile(for provider: HarnessProvider) -> some View {
        Button { model.choose(provider) } label: {
            VStack(spacing: 8) {
                HarnessProviderIcon(provider: provider)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(name(provider)).font(.headline)
                    if let maker = FirstBotSetup.maker(provider) {
                        Text("by \(maker)").font(.caption).foregroundStyle(.secondary)
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
        .disabled(![.install, .signIn, .ready].contains(model.readiness(provider)))
        .accessibilityLabel(FirstBotSetup.maker(provider).map { "\(name(provider)) by \($0)" } ?? name(provider))
    }

    private func name(_ provider: HarnessProvider) -> String {
        FirstBotSetup.accountName(provider) ?? provider.displayName
    }

    /// The download is part of signing in, so a harness that is not installed asks for sign-in too.
    private func status(for provider: HarnessProvider) -> SettingsStatusLabel {
        switch model.readiness(provider) {
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
                Task { await setup.refreshAll(store.runtime) }
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
                        BotAvatar(agent: bot, size: 64)
                        Text(bot.displayName).font(.headline)
                        Text(StarterTeam.members[index].role).font(.caption).foregroundStyle(.secondary)
                    }
                    // Equal columns, so the middle one sits under the wordmark whatever the roles say.
                    .frame(width: 140)
                    .accessibilityElement(children: .combine)
                }
            }
            Button("Continue") {
                if let teamGroupID { store.greetStarterTeam(in: teamGroupID) }
                store.finishFirstBotSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    private var nameStyle: BotNameStyle { BotNameStyle(rawValue: botNameStyle) ?? .real }
}
