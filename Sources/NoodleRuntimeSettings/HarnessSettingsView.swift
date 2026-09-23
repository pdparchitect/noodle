import AppKit
import SwiftUI
import NoodleCore
import NoodleSettingsUI
import NoodleRuntime

public struct HarnessesSettingsView: View {
    let store: any BotSettingsHost
    let setup: HarnessSetupController
    @State private var showRefreshProgress = false

    public init(store: any BotSettingsHost, setup: HarnessSetupController) {
        self.store = store
        self.setup = setup
    }

    private var isRefreshing: Bool {
        setup.refreshingAll || store.runtime.isRefreshingInstallations || !setup.checking.isEmpty || setup.checkingVersions
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(setup.displayedInstallations) { installation in
                        HarnessInstallationRow(store: store, installation: installation,
                            liveInstallation: store.runtime.installations.first { $0.provider == installation.provider },
                            isRefreshing: isRefreshing, setup: setup) {
                            Task {
                                await store.runtime.checkExternalInstallation(installation.provider)
                                guard !store.runtime.isRefreshingInstallations else { return }
                                await setup.refresh(store.runtime.installations, discoveryErrors: store.runtime.installationErrors)
                                await setup.refreshVersions(store.runtime.installations, forceLatest: true)
                            }
                        }
                    }
                }
                if setup.displayedInstallations.contains(where: setup.isManaged) {
                    Section {
                        @Bindable var setup = setup
                        Toggle("Update harnesses installed by Noodle automatically", isOn: $setup.automaticUpdates)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(showRefreshProgress ? 1 : 0)
                    .accessibilityLabel("Checking for harnesses")
                    .accessibilityHidden(!showRefreshProgress)
                Button("Check Again") {
                    Task { await refresh(forceLatest: true) }
                }
                .disabled(isRefreshing)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .task { await refresh() }
        .task(id: isRefreshing) {
            showRefreshProgress = false
            guard isRefreshing else { return }
            // Quick background checks should not flash a spinner or replace status.
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            showRefreshProgress = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onDisappear { setup.cancelAll() }
    }

    private func refresh(forceLatest: Bool = false) async {
        await setup.refreshAll(store.runtime, forceLatest: forceLatest)
    }

}

public struct HarnessInstallationRow: View {
    let store: any BotSettingsHost
    let installation: HarnessInstallation
    let liveInstallation: HarnessInstallation?
    let isRefreshing: Bool
    let setup: HarnessSetupController
    let install: () -> Void
    @State private var showsInstallationGuide = false
    @State private var hasCheckedInstallation = false
    @State private var terminalError: String?
    @State private var showsUpdateGuide = false
    @State private var showsExperimentalInfo = false
    @State private var showsLocalModels = false
    @State private var showsProfiles = false
    @State private var confirmsRemoval = false
    @State private var kickRequest: AgentKickRequest?
    @State private var showsAgentIssues = false
    @Environment(\.openURL) private var openURL

    private var id: HarnessProvider { installation.provider }

    private var affectedAgents: [AgentRecord] {
        store.agents.filter {
            $0.harnessIdentifier == id.rawValue && store.runtime.snapshot(for: $0.id).canKick
        }
    }

    private var hasFailedAgents: Bool {
        affectedAgents.contains { store.runtime.snapshot(for: $0.id).phase == .failed }
    }

    private var hasReconnectingAgents: Bool {
        affectedAgents.contains { store.runtime.snapshot(for: $0.id).reconnectingSince != nil }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HarnessProviderIcon(provider: installation.provider)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .padding(2)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(installation.provider.displayName)
                        .fontWeight(.semibold)
                    if id.isExperimental {
                        Button("Experimental") { showsExperimentalInfo.toggle() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Why is this harness experimental?")
                            .popover(isPresented: $showsExperimentalInfo) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Experimental")
                                        .font(.headline)
                                    Text("Apple’s on-device model can respond slowly, miss details from earlier messages, or fail to complete tool tasks. This harness is still being tested.")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(20)
                                .frame(width: 360, alignment: .leading)
                            }
                    }
                    Spacer()
                    statusLabel
                }

                if let path = installation.executablePath {
                    Text(id == .apple ? "Local" : (setup.isManaged(installation) ? "Installed by Noodle" : path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(setup.snapshots[id] == nil ? "Checking the installation…" : "Install the native harness to use it with Noodle.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let error = setup.errors[id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installation.isAvailable {
                    versionDetails
                }
                if needsSignIn, setup.authentication[id] == .managedExternally {
                    Text("Could not determine the saved sign-in status.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                actionButtons
                if installation.isAvailable {
                    updateGuide
                }
                if let activity = setup.activity[id] {
                    HStack {
                        if let fraction = setup.installProgress[id] {
                            ProgressView(value: fraction).frame(width: 120)
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
                } else if setup.activity[id] == nil {
                    if !installation.isAvailable && setup.snapshots[id] != nil {
                        if showsInstallationGuide, let guide = setup.installationGuide(for: id) {
                            Text(guide.instructions).font(.caption).foregroundStyle(.secondary)
                            if let command = guide.command {
                                HarnessCommandView(command: command)
                                Button("Open Terminal") { openTerminal() }
                            }
                            HStack {
                                Link("Installation Guide", destination: guide.documentationURL)
                                Spacer()
                                Button("Check Installation") {
                                    hasCheckedInstallation = true
                                    install()
                                }.disabled(setup.checking.contains(id))
                            }
                            if hasCheckedInstallation {
                                Text("Not detected yet. Finish the installer in Terminal, then check again.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let terminalError { Text(terminalError).font(.caption).foregroundStyle(.red) }
                        } else if setup.canInstall(id) {
                            HStack {
                                Button("Install") { setup.install(id, runtime: store.runtime) }
                                Button("Install Manually…") { showsInstallationGuide = true }
                            }
                        } else {
                            Button("Install…") { showsInstallationGuide = true }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .modifier(AgentKickConfirmation(store: store, request: $kickRequest))
    }

    @ViewBuilder private var statusLabel: some View {
        let label = SettingsStatusLabel(title: statusText, systemImage: statusIcon, color: statusColor)
        if affectedAgents.isEmpty {
            label
        } else {
            Button { showsAgentIssues.toggle() } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Show affected bots")
                .popover(isPresented: $showsAgentIssues, arrowEdge: .bottom) { agentIssues }
        }
    }

    private var agentIssues: some View {
        SettingsBotListLayout {
            ViewThatFits(in: .vertical) {
                agentIssueRows
                ScrollView { agentIssueRows }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    private var agentIssueRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(affectedAgents.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.displayName).fontWeight(.semibold)
                    let snapshot = store.runtime.snapshot(for: agent.id)
                    if let since = snapshot.reconnectingSince {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                            Text("Reconnecting… · \(seconds / 60)m \(seconds % 60)s")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text(snapshot.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Button("Kick") {
                        showsAgentIssues = false
                        kickRequest = store.runtime.kick(agent: agent, repository: store.repository)
                    }
                    .controlSize(.small)
                    .disabled(store.runtime.changingAccess.contains(agent.id))
                    .padding(.top, 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openTerminal() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            terminalError = "Open your preferred terminal and paste the installation command."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            Task { @MainActor in
                terminalError = error == nil ? nil : "Could not open Terminal. Open it manually and paste the installation command."
            }
        }
    }

    @ViewBuilder private var versionDetails: some View {
        let version = setup.snapshots[id]?.version
        HStack(spacing: 8) {
            Text(version?.installedVersion.map { "Version \($0)" } ?? "Version not checked yet")
                .font(.caption).foregroundStyle(.secondary)
            if version?.compatibilityIssue != nil {
                Label("Update required", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if version?.updateAvailable == true {
                Text("Update available\(version?.latestVersion.map { " — \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        if let issue = version?.compatibilityIssue {
            Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if let error = version?.checkError {
            if isRefreshing {
                Text("Checking for updates…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Sign In is offered once nothing else is in progress for an installed harness.
    private var needsSignIn: Bool {
        guard setup.challenges[id] == nil, setup.activity[id] == nil,
              installation.isAvailable || setup.snapshots[id] == nil else { return false }
        return setup.authentication[id] == .unauthenticated || setup.authentication[id] == .managedExternally
    }

    /// Every button of the row shares one line.
    @ViewBuilder private var actionButtons: some View {
        let version = setup.snapshots[id]?.version
        let available = installation.isAvailable
        let managed = available && setup.isManaged(installation)
        let updateAvailable = available && version?.updateAvailable == true
        if (available && id.supportsProfiles) || updateAvailable || managed || id == .apple || needsSignIn {
            HStack(spacing: 12) {
                if available, id.supportsProfiles {
                    Button("Profiles") { showsProfiles = true }
                        .buttonStyle(.link)
                        .sheet(isPresented: $showsProfiles) {
                            HarnessProfilesView(store: store, installation: liveInstallation ?? installation)
                                .noodleSheetSizing(animated: true)
                        }
                }
                if updateAvailable {
                    if managed {
                        Button("Update") { setup.install(id, runtime: store.runtime) }
                            .buttonStyle(.link)
                            .disabled(setup.activity[id] != nil)
                    } else {
                        Button("Update Instructions") { showsUpdateGuide.toggle() }
                            .buttonStyle(.link)
                    }
                }
                if managed {
                    Button("Remove") { confirmsRemoval = true }
                        .buttonStyle(.link)
                        .disabled(setup.activity[id] != nil)
                        .confirmationDialog("Remove \(id.displayName)?", isPresented: $confirmsRemoval) {
                            Button("Remove", role: .destructive) {
                                // A running bot would lose the tools beside its executable mid-turn.
                                for agent in store.agents where agent.harnessIdentifier == id.rawValue {
                                    store.runtime.stop(agentID: agent.id, revokeAccess: false)
                                }
                                setup.removeManaged(id, runtime: store.runtime)
                            }
                        } message: {
                            Text("Bots that use \(id.displayName) stop working until it is installed again. Your sign-in is kept.")
                        }
                }
                if id == .apple {
                    Button("Local Models") { showsLocalModels = true }
                        .buttonStyle(.link)
                        .sheet(isPresented: $showsLocalModels) { AppleLocalModelsView(store: store).noodleSheetSizing(animated: true) }
                }
                if needsSignIn {
                    Button("Sign In") {
                        if let liveInstallation, liveInstallation.isAvailable { setup.signIn(liveInstallation) }
                    }
                        .buttonStyle(.link)
                        // Only this harness's own check matters; version lookups and the
                        // other harnesses' checks would otherwise keep the link disabled.
                        .disabled(setup.checking.contains(id) || liveInstallation?.isAvailable != true)
                }
            }
        }
    }

    @ViewBuilder private var updateGuide: some View {
        let version = setup.snapshots[id]?.version
        if version?.updateAvailable == true, showsUpdateGuide, !setup.isManaged(installation) {
            let guide = HarnessVersionPolicy.updateGuide(for: installation)
            Text(guide.instructions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let command = guide.command {
                HarnessCommandView(command: command)
            }
            HStack {
                if guide.command != nil {
                    Button("Open Terminal") { openTerminal() }
                }
                Button("Official Update Guide") { openURL(guide.documentationURL) }
            }
            if let terminalError { Text(terminalError).font(.caption).foregroundStyle(.red) }
        }
    }

    private var statusText: String {
        if setup.activity[id] != nil { return "Setting up" }
        if setup.errors[id] != nil || hasFailedAgents { return "Needs attention" }
        if hasReconnectingAgents { return "Reconnecting" }
        if setup.snapshots[id] == nil { return "Checking…" }
        if !installation.isAvailable { return "Not installed" }
        switch setup.authentication[id] {
        case .authenticated: return "Signed in"
        case .unauthenticated: return "Sign-in required"
        case .notRequired: return "Ready"
        case .managedExternally: return "Sign-in status unknown"
        case nil: return setup.checking.contains(id) ? "Checking sign-in…" : "Installed"
        }
    }

    private var statusIcon: String {
        if setup.errors[id] != nil || hasFailedAgents { return "exclamationmark.triangle" }
        if hasReconnectingAgents { return "arrow.trianglehead.2.clockwise" }
        if setup.snapshots[id] == nil { return "ellipsis.circle" }
        if !installation.isAvailable { return "arrow.down.circle" }
        return setup.authentication[id] == .authenticated || setup.authentication[id] == .notRequired
            ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark"
    }

    private var statusColor: Color {
        if setup.errors[id] != nil || hasFailedAgents || hasReconnectingAgents { return .orange }
        if setup.authentication[id] == .authenticated || setup.authentication[id] == .notRequired { return .green }
        return .secondary
    }
}

private struct HarnessCommandView: View {
    let command: String

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Copy Command", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy command")
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }
}
