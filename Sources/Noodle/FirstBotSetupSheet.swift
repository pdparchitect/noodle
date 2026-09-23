import SwiftUI
import NoodleCore
import NoodleRuntime

struct FirstBotSetupSheet: View {
    @Environment(NoodleStore.self) private var store
    @AppStorage(BotNameStyle.defaultsKey) private var botNameStyle = BotNameStyle.real.rawValue
    @State private var model: FirstBotSetup
    @State private var name = ""
    @State private var avatarColorIndex = Int.random(in: BotAvatarPalette.gradients.indices)
    @FocusState private var nameFocused: Bool

    init(setup: HarnessSetupController, runtime: AgentRuntimeCoordinator) {
        _model = State(initialValue: FirstBotSetup(setup: setup, runtime: runtime))
    }

    private var setup: HarnessSetupController { store.harnessSetup }
    private var id: HarnessProvider { model.selection }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                switch model.step {
                case .harness: harnessStep
                case .prepare: prepareStep
                case .bot: botStep
                }
            }
            .padding(20)
        }
        .frame(width: 640)
        .task { await setup.refreshAll(store.runtime) }
        .onChange(of: model.readiness(id)) { _, _ in model.advanceIfReady() }
        .onChange(of: model.step) { _, step in
            guard step == .bot else { return }
            if name.isEmpty { name = BotNameGenerator.random(style: nameStyle) }
            nameFocused = true
        }
    }

    private var header: some View {
        HStack {
            Button(model.step == .harness ? "Not Now" : "Back") {
                if model.step == .harness { store.finishFirstBotSetup() } else { model.back() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            Spacer()
            Text(store.agents.isEmpty ? "Set Up Your First Bot" : "Set Up a Bot").font(.headline)
            Spacer()
            Button(model.step == .bot ? "Create" : "Continue") {
                if model.step == .bot { create() } else { model.proceed() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canAct ? Color.blue : .secondary)
            .disabled(!canAct)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var canAct: Bool {
        model.step == .bot ? ConversationName.error(for: name) == nil : model.canContinue
    }

    private var harnessStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(FirstBotSetup.featured) { provider in
                    tile(for: provider)
                }
            }
            Button { model.othersRevealed.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.showsOthers ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Other").font(.subheadline.weight(.medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model.showsOthers ? .isSelected : [])
            .animation(.easeInOut(duration: 0.15), value: model.showsOthers)
            if model.showsOthers { harnessList }
        }
    }

    private func tile(for provider: HarnessProvider) -> some View {
        Button { model.chosen = provider } label: {
            VStack(spacing: 8) {
                HarnessProviderIcon(provider: provider)
                    .foregroundStyle(provider == id ? Color.accentColor : .secondary)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(vendorName(provider)).font(.headline)
                    Text(provider.displayName).font(.caption).foregroundStyle(.secondary)
                }
                status(for: provider)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
            .background(provider == id ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(provider == id ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(vendorName(provider)), \(provider.displayName)")
        .accessibilityAddTraits(provider == id ? .isSelected : [])
    }

    private func vendorName(_ provider: HarnessProvider) -> String {
        switch provider {
        case .codex: "OpenAI"
        case .claudeCode: "Anthropic"
        case .muse: "Meta"
        case .grokBuild: "xAI"
        case .fx, .openCode, .antigravity, .apple: provider.displayName
        }
    }

    private var harnessList: some View {
        VStack(spacing: 2) {
            ForEach(FirstBotSetup.others) { provider in
                Button { model.chosen = provider } label: {
                    HStack(spacing: 12) {
                        HarnessProviderIcon(provider: provider)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        Text(provider.displayName)
                        if provider.isExperimental {
                            Text("Experimental").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        status(for: provider)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .background(provider == id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(provider == id ? .isSelected : [])
            }
        }
    }

    private func status(for provider: HarnessProvider) -> SettingsStatusLabel {
        switch model.readiness(provider) {
        case .checking: SettingsStatusLabel(title: "Checking…", systemImage: "ellipsis.circle", color: .secondary)
        case .ready: SettingsStatusLabel(title: "Ready", systemImage: "checkmark.circle.fill", color: .green)
        case .signIn: SettingsStatusLabel(title: "Sign-in required", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)
        case .install: SettingsStatusLabel(title: "Not installed", systemImage: "arrow.down.circle", color: .secondary)
        case .unavailable: SettingsStatusLabel(title: "Unavailable", systemImage: "minus.circle", color: .secondary)
        }
    }

    @ViewBuilder private var prepareStep: some View {
        HStack(spacing: 12) {
            HarnessProviderIcon(provider: id)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(id.displayName).fontWeight(.semibold)
            Spacer()
            status(for: id)
        }
        if let activity = setup.activity[id] {
            HStack {
                if let fraction = setup.installProgress[id] {
                    ProgressView(value: fraction).frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(activity).font(.caption)
                Spacer()
                Button("Cancel") { setup.cancel(id) }
            }
        }
        if let challenge = setup.challenges[id] {
            HarnessSignInChallengeView(challenge: challenge)
        }
        if let error = setup.errors[id] {
            Text(error).font(.caption).foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if setup.activity[id] == nil, setup.challenges[id] == nil {
            switch model.readiness(id) {
            case .install: Button("Install") { model.install() }
            case .signIn: Button("Sign In…") { model.signIn() }
            case .checking, .ready, .unavailable: EmptyView()
            }
        }
    }

    private var botStep: some View {
        HStack(spacing: 14) {
            BotAvatar(agent: AgentRecord(displayName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bot" : name,
                                         accentSeed: avatarColorIndex, avatarSymbolName: "sparkles",
                                         avatarColorIndex: avatarColorIndex, avatarImageData: nil), size: 64)
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .trailing) {
                    TextField("Bot name", text: $name, axis: .horizontal)
                        .lineLimit(1)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                        .focused($nameFocused)
                        .onSubmit { if canAct { create() } }
                    Button {
                        name = BotNameGenerator.random(style: nameStyle, excluding: name)
                        nameFocused = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .help("Try Another Name")
                    .accessibilityLabel("Generate Another Name")
                }
                NameValidationMessage(name: name)
            }
        }
    }

    private var nameStyle: BotNameStyle { BotNameStyle(rawValue: botNameStyle) ?? .real }

    private func create() {
        guard store.createAgent(named: name, harnessIdentifier: id.rawValue, modelIdentifier: nil, reasoningEffort: nil,
                                avatarSymbolName: "sparkles", avatarColorIndex: avatarColorIndex, avatarImageData: nil,
                                publicDescription: "", backstory: "", mcpConnectionIDs: [], computerIDs: [], browserIDs: [],
                                folders: [], harnessProfile: nil) else { return }
        store.finishFirstBotSetup()
    }
}
