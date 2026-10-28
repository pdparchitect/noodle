import SwiftUI
import NoodleCore
import NoodleRuntime

/// Separate logins for one harness, opened from its Settings row.
public struct HarnessProfilesView: View {
    let store: any BotSettingsHost
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let installation: HarnessInstallation
    @State private var naming: NamingRequest?
    @State private var name = ""
    @State private var deleting: HarnessProfile?
    @State private var signingOut: HarnessProfile?
    /// The profile whose sign-in popover is open.
    @State private var showsSignIn: UUID?
    @State private var error: String?

    private enum NamingRequest {
        case create, rename(HarnessProfile)
    }

    private var controller: HarnessProfilesController { store.harnessProfiles }
    private var profiles: [HarnessProfile] { controller.profiles(for: installation.provider) }

    /// Profiles a bot on them waits to sign in to again. The sign-in check only reads the
    /// saved login, so it still says signed in after the vendor refused that login. Only
    /// bots waiting for sign-in have their profile read.
    private var profilesWaitingForSignIn: Set<UUID> {
        Set(store.agents.compactMap { agent in
            guard agent.harnessIdentifier == installation.provider.rawValue,
                  store.runtime.snapshot(for: agent.id).failure == .authenticationRequired,
                  store.runtime.runningHarness(for: agent.id) == nil else { return nil }
            return try? store.repository.loadAgentHarnessProfile(agent)
        })
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(installation.provider.displayName) Profiles").font(.title2.bold())

                if profiles.isEmpty {
                    Text("No profiles").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    let waiting = profilesWaitingForSignIn
                    VStack(spacing: 0) {
                        ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                            if index > 0 { Divider() }
                            row(profile, waitingForSignIn: waiting.contains(profile.id))
                        }
                    }
                    .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.11))
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Button("Add Profile…") { name = ""; naming = .create }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await controller.refresh(installation) }
        .onDisappear { controller.cancelAll() }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Profile name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }
                .disabled(ConversationName.error(for: name) != nil)
        }
        .alert("Delete Profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { profile in
            Button("Delete", role: .destructive) { store.deleteHarnessProfile(profile) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { profile in
            Text("“\(profile.displayName)” is signed out of Noodle. Bots using it return to the Default sign-in and restart.")
        }
        .alert(Text("Sign Out of “\(signingOut?.displayName ?? "")”?"),
               isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }),
               presenting: signingOut) { profile in
            Button("Sign Out", role: .destructive) {
                controller.signOut(profile) { [store] in store.restartAgents(signedInWith: profile) }
            }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("Bots that use this profile pause until you sign in again.")
        }
    }

    private var namingTitle: String {
        if case .rename = naming { return "Rename Profile" }
        return "New Profile"
    }

    private func row(_ profile: HarnessProfile, waitingForSignIn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).fontWeight(.medium).lineLimit(1)
                    status(profile, waitingForSignIn: waitingForSignIn)
                }
                Spacer(minLength: 8)
                if controller.activity[profile.id] != nil {
                    Button("Cancel") { controller.cancel(profile) }
                } else if waitingForSignIn
                            || controller.authentication[profile.id] != .authenticated && controller.authentication[profile.id] != .notRequired {
                    Button("Sign In…") { controller.signIn(profile, installation: installation) }
                }
                Menu {
                    HarnessUsageRetryToggle(harnesses: store.runtime.harnesses,
                        target: HarnessFallbackTarget(provider: profile.provider, profile: profile.id))
                    Divider()
                    if controller.activity[profile.id] == nil, controller.authentication[profile.id] == .authenticated, !waitingForSignIn {
                        // A login can be revoked on the server while still reading as signed in here.
                        Button("Sign In Again…") { controller.signIn(profile, installation: installation) }
                    }
                    Button("Rename…") { name = profile.displayName; naming = .rename(profile) }
                    Button("Delete", role: .destructive) { deleting = profile }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Profile Actions")
            }
            if controller.activity[profile.id] == nil, controller.authentication[profile.id] == .authenticated,
               SubscriptionUsage.isReported(by: installation.provider) {
                SubscriptionUsageView(usage: store.runtime.subscriptionUsage.usage(installation.provider, profile: profile.id))
                    .padding(.leading, 34)
            }
            if let challenge = controller.challenges[profile.id] {
                HarnessSignInChallengeView(challenge: challenge)
            }
            if let command = controller.terminalSignIns[profile.id] {
                HarnessTerminalSignInView(command: command) { Task { await controller.refresh(installation) } }
            }
            if let error = controller.errors[profile.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// A status about signing in opens the profile's sign-in, as a harness's row does.
    @ViewBuilder private func status(_ profile: HarnessProfile, waitingForSignIn: Bool) -> some View {
        if controller.activity[profile.id] == nil,
           let menu = HarnessSignInMenu.make(status: controller.authentication[profile.id], waitingForSignIn: waitingForSignIn,
                                             account: controller.accounts[profile.id], busy: controller.challenges[profile.id] != nil) {
            Button { showsSignIn = profile.id } label: {
                statusLabel(profile, waitingForSignIn: waitingForSignIn).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show sign-in")
            .popover(isPresented: Binding(get: { showsSignIn == profile.id }, set: { if !$0 { showsSignIn = nil } }),
                     arrowEdge: .bottom) {
                HarnessSignInSection(menu: menu, name: profile.displayName, isDefault: false) { action in
                    showsSignIn = nil
                    switch action {
                    case .signIn, .signInAgain: controller.signIn(profile, installation: installation)
                    case .signOut: signingOut = profile
                    }
                }
                .frame(width: 340, alignment: .leading)
            }
        } else {
            statusLabel(profile, waitingForSignIn: waitingForSignIn)
        }
    }

    @ViewBuilder private func statusLabel(_ profile: HarnessProfile, waitingForSignIn: Bool) -> some View {
        if let activity = controller.activity[profile.id] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(activity).font(.caption).foregroundStyle(.secondary)
            }
        } else if waitingForSignIn {
            SettingsStatusLabel(title: "Sign-in required", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)
        } else {
            switch controller.authentication[profile.id] {
            case .authenticated:
                SettingsStatusLabel(title: "Signed in", systemImage: "checkmark.circle.fill", color: .green)
            case .unauthenticated:
                SettingsStatusLabel(title: "Sign-in required", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)
            case .notRequired:
                SettingsStatusLabel(title: "Ready", systemImage: "checkmark.circle.fill", color: .green)
            case .managedExternally, nil:
                Text(controller.errors[profile.id] == nil ? "Checking sign-in…" : "Sign-in status unknown")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveName() {
        do {
            switch naming {
            case .create:
                _ = try controller.create(provider: installation.provider, named: name)
                Task { await controller.refresh(installation) }
            case .rename(let profile): try controller.rename(profile, to: name)
            case nil: break
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        naming = nil
    }
}

/// Shared by a named profile's actions and the harness's Default-login actions.
struct HarnessUsageRetryToggle: View {
    let harnesses: HarnessSelection
    let target: HarnessFallbackTarget

    var body: some View {
        Toggle("Use for Usage Retries", isOn: Binding(
            get: { harnesses.allowsUsageRetries(target) },
            set: { harnesses.setUsageRetries(target, on: $0) }))
            .help("Allow this login when another profile on the same harness runs out of usage, before trying the fallback list. The bot keeps its model. This works even when the fallback list is off.")
    }
}
