import AppKit
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import PionCore
import SwiftUI

/// Pion's first launch, in the main window, as Noodle's: Pion's mark appears, then the steps to get an account
/// ready, which make the starter team and the group they share. Choosing, installing and signing in are Noodle's
/// own first-run steps; leaving counts as Not Now, and Help > Welcome brings it back.
struct WelcomeView: View {
    let model: PionModel
    let setup: HarnessSetupController
    @State private var shown = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                PionSymbol()
                    .frame(width: 72, height: 72)
                Text("Welcome to \(pionAppName)")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            if shown {
                WelcomeSteps(model: model, setup: setup)
                    .transition(.opacity.combined(with: .offset(y: 24)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.smooth(duration: 0.5)) { shown = true }
        }
    }
}

/// Pion's mark, drawn in the text colour.
private struct PionSymbol: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "AppSymbol", withExtension: "svg").flatMap {
        let image = NSImage(contentsOf: $0)
        image?.isTemplate = true
        return image
    }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit().foregroundStyle(.primary).accessibilityHidden(true)
        } else {
            Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}

/// Choose an account, get it ready, meet the team.
private struct WelcomeSteps: View {
    let model: PionModel
    let setup: HarnessSetupController
    @State private var steps: FirstBotSetup
    /// The agents made once the account is ready, shown before their group opens.
    @State private var team: [AgentRecord] = []
    @State private var groupID: UUID?

    init(model: PionModel, setup: HarnessSetupController) {
        self.model = model
        self.setup = setup
        _steps = State(initialValue: FirstBotSetup(setup: setup, runtime: model.runtime, accounts: PionHarnesses.featured))
    }

    private var id: HarnessProvider { steps.selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch steps.step {
            case .harness: harnessStep
            // Its actions follow the step's progress, so they read as links beside it.
            case .prepare: prepareStep.buttonStyle(.link)
            case .team: teamStep
            }
            if steps.step == .prepare { navigation }
        }
        .padding(20)
        .frame(width: 640)
        .task { await setup.refreshAll(model.runtime) }
        .onChange(of: steps.readiness(id)) { _, _ in steps.advanceIfReady() }
        // A download reports the sign-in it needs before it stops being busy.
        .onChange(of: steps.isBusy) { _, _ in steps.advanceIfReady() }
        .onChange(of: steps.step) { _, step in
            guard step == .team else { return }
            do {
                // Someone with agents came back through Help > Welcome to set up an account, and is done.
                guard let made = try model.createStarterTeamIfFirst(on: id) else { return model.finishWelcome() }
                team = made.team
                groupID = made.group.id
            } catch {
                model.problem = error.localizedDescription
                steps.back()
            }
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
        .buttonStyle(.link)
    }

    private var harnessStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ForEach(steps.accounts) { tile(for: $0) }
            }
            Button("Not Now") { model.finishWelcome() }
                .buttonStyle(.link)
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
                    // Apple Intelligence has no account; it runs on this Mac.
                    Text(FirstBotSetup.maker(provider).map { "by \($0)" } ?? "on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
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
                Task { await setup.refreshAll(model.runtime) }
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
                ForEach(Array(team.enumerated()), id: \.element.id) { index, agent in
                    VStack(spacing: 6) {
                        AgentMark(agent: agent, size: 64)
                        Text(agent.displayName).font(.headline).multilineTextAlignment(.center)
                        Text(PionStarterTeam.members[index].role).font(.caption).foregroundStyle(.secondary)
                    }
                    // Equal columns, so the middle one sits under the title whatever the roles say.
                    .frame(width: 160)
                    .accessibilityElement(children: .combine)
                }
            }
            Button("Continue") {
                if let groupID { model.introduceStarterTeam(in: groupID) }
                model.finishWelcome()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }
}
