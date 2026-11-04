import SwiftUI
import NoodleCore
import NoodleRuntime

/// What a login's sign-in status offers when clicked: who it is signed in as, and how to
/// sign in or out. Only for a login of the app's own, a harness's Default or a profile.
public struct HarnessSignInMenu: Equatable {
    public enum Action: Equatable, Hashable {
        case signIn, signInAgain, signOut

        var title: String {
            switch self {
            case .signIn: "Sign In"
            case .signInAgain: "Sign In Again"
            case .signOut: "Sign Out"
            }
        }
    }

    public let account: String?
    public let actions: [Action]

    /// Nil when the status says nothing about signing in, or the login is busy.
    /// `waitingForSignIn` is a bot on the login that the vendor refused, though the
    /// saved login still reads as signed in.
    public static func make(status: HarnessAuthenticationStatus?, waitingForSignIn: Bool,
                            account: String?, busy: Bool) -> HarnessSignInMenu? {
        guard !busy else { return nil }
        switch status {
        case .unauthenticated: return HarnessSignInMenu(account: nil, actions: [.signIn])
        case _ where waitingForSignIn: return HarnessSignInMenu(account: nil, actions: [.signIn, .signOut])
        case .authenticated: return HarnessSignInMenu(account: account, actions: [.signInAgain, .signOut])
        case .managedExternally: return HarnessSignInMenu(account: nil, actions: [.signIn, .signOut])
        case .notRequired, nil: return nil
        }
    }
}

/// A login's part of a status popover, laid out like the bots listed above it.
struct HarnessSignInSection: View {
    let menu: HarnessSignInMenu
    /// "Default", or the profile's name.
    let name: String
    let isDefault: Bool
    let perform: (HarnessSignInMenu.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isDefault ? "house" : "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(menu.account ?? name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if menu.account != nil {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(menu.actions, id: \.self) { action in
                    Button(action.title) { perform(action) }
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public extension BotSettingsHost {
    /// The bots a login signs in: those on the profile, or, for a harness's Default
    /// login, those of the harness that chose no profile.
    func agents(signedInWith profile: HarnessProfile) -> [AgentRecord] {
        let isDefault = profile.id == HarnessProfileStore.defaultID(profile.provider)
        return agents.filter { agent in
            guard agent.harnessIdentifier == profile.provider.rawValue else { return false }
            let chosen = (try? repository.loadAgentHarnessProfile(agent)) ?? nil
            return chosen == profile.id || isDefault && chosen == nil
        }
    }

    /// Bots keep a copy of the login they started with; restarting them drops a signed-out
    /// one, so they wait for the next sign-in instead.
    func restartAgents(signedInWith profile: HarnessProfile) {
        for agent in agents(signedInWith: profile) { runtime.restart(agent: agent, repository: repository) }
    }
}

/// The Vercel team an FX login sends model requests through, as checkmark items;
/// shown with its divider only when the login can choose between teams.
struct FxTeamMenu: View {
    let teams: [FxTeam]
    let busy: Bool
    let select: (FxTeam) -> Void

    var body: some View {
        if teams.count > 1 {
            Menu("Vercel Team") {
                ForEach(teams, id: \.slug) { team in
                    Toggle(team.name, isOn: Binding(get: { team.isSelected }, set: { if $0 { select(team) } }))
                }
            }
            .disabled(busy)
            Divider()
        }
    }
}
