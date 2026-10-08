import HubLink
import NoodleBrand
import SwiftUI

/// Makes the starter team on the first Hub a phone joins, as Noodle's welcome does on the Mac, on the
/// first harness the Hub lends, so there is nothing to set up.
@MainActor @Observable final class HubWelcome {
    enum Stage: Equatable {
        /// Asking the Hub whether the person has bots there already.
        case checking
        case making
        case ready
        /// They have bots or groups on the Hub, so there is no team to make.
        case skipped
        case failed(String)
    }

    let chats: HubChats
    private(set) var stage = Stage.checking
    /// The members made so far, in the team's order.
    private(set) var team: [LinkBot] = []
    private(set) var group: LinkGroup?

    init(pairing: HubPairing) {
        chats = HubChats(pairing: pairing)
    }

    /// Makes what is not made yet, so trying again after a failure finishes the same team.
    func make() async {
        do {
            if team.isEmpty {
                stage = .checking
                try await chats.reload()
                guard chats.agents.isEmpty, chats.groups.isEmpty else { stage = .skipped; return }
            }
            guard let harness = chats.pairing.status?.harnesses.first else {
                stage = .failed("Your plan lends no harnesses, so there is no team yet. Ask the Hub's admin to add one.")
                return
            }
            stage = .making
            let names = StarterTeam.names(style: .real, avoiding: Set(chats.agents.map(\.draft.name)))
            for (member, name) in zip(StarterTeam.members, names).dropFirst(team.count) {
                let bot = try await chats.create(LinkBotDraft(
                    name: name, provider: harness.provider, profile: harness.profile, model: harness.initialModel,
                    publicDescription: member.publicDescription, backstory: member.backstory,
                    avatarSymbolName: member.symbol, avatarColorIndex: member.colorIndex))
                team.append(bot)
            }
            if group == nil {
                group = try await chats.createGroup(LinkGroupDraft(name: StarterTeam.groupName, publicDescription: StarterTeam.groupDescription,
                                                                   botIDs: team.map(\.id)))
            }
            stage = .ready
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Sends the person's first message to the team. One that does not go through waits in the group to try again.
    func greet() async {
        guard let group else { return }
        try? await chats.send(StarterTeam.greeting, to: group)
    }
}

/// Shown once the first Hub is joined: the wordmark rises from where pairing left it, the team comes in
/// one by one as the Hub makes them, and Continue opens their group with a hello.
struct HubWelcomeView: View {
    /// The group to open, or nil to show the list.
    let done: (LinkGroup?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var welcome: HubWelcome
    @State private var lifted = false
    @State private var greeting = false

    init(pairing: HubPairing, done: @escaping (LinkGroup?) -> Void) {
        self.done = done
        _welcome = State(initialValue: HubWelcome(pairing: pairing))
    }

    /// As on the pairing screen, so the wordmark stays put when this one takes over.
    private static let wordWidth: CGFloat = 220
    private static let liftedScale: CGFloat = 0.6
    private static let liftedCentre: CGFloat = 48

    var body: some View {
        GeometryReader { proxy in
            let screenHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            ZStack {
                Wordmark(progress: 1, wordWidth: Self.wordWidth)
                    .stroke(.primary, style: StrokeStyle(
                        lineWidth: Wordmark.lineWidth(forWordWidth: Self.wordWidth), lineCap: .round, lineJoin: .round))
                    .scaleEffect(lifted ? Self.liftedScale : 1)
                    .offset(y: lifted ? proxy.safeAreaInsets.top + Self.liftedCentre - screenHeight / 2 : 0)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel("Noodle")
                    .accessibilityAddTraits(.isHeader)
                if lifted {
                    VStack(spacing: 32) {
                        Spacer().frame(height: Self.liftedCentre + 24)
                        members
                        if case .failed(let message) = welcome.stage {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                        actions
                    }
                    .padding(24)
                    .transition(.opacity.combined(with: .offset(y: 24)))
                }
            }
        }
        .task { await welcome.make() }
        .onChange(of: welcome.stage) { _, stage in
            switch stage {
            case .skipped: done(nil)
            case .checking: break
            case .making, .ready, .failed: lift()
            }
        }
    }

    /// One column per member: a place for them while the Hub makes them, then their picture and name.
    private var members: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(StarterTeam.members.enumerated()), id: \.offset) { index, member in
                let bot = welcome.team.indices.contains(index) ? welcome.team[index] : nil
                VStack(spacing: 6) {
                    ZStack {
                        if let bot {
                            AgentAvatar(draft: bot.draft, size: 64)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        } else {
                            Circle().fill(.quaternary)
                            if welcome.stage == .making || welcome.stage == .checking { ProgressView() }
                        }
                    }
                    .frame(width: 64, height: 64)
                    Text(bot?.draft.name ?? " ").font(.headline)
                    Text(member.role).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                // Equal columns, so the middle one sits under the wordmark whatever the roles say.
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.35), value: welcome.team.count)
    }

    @ViewBuilder private var actions: some View {
        if case .failed = welcome.stage {
            VStack(spacing: 12) {
                Button { Task { await welcome.make() } } label: {
                    Text("Try Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Not Now") { done(welcome.group) }
            }
        } else {
            Button {
                greeting = true
                Task {
                    await welcome.greet()
                    done(welcome.group)
                }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(welcome.stage != .ready || greeting)
        }
    }

    private func lift() {
        guard !lifted else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.1)) { lifted = true }
    }
}
