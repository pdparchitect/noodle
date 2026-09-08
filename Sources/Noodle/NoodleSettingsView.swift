import AppKit
import SwiftUI
import NoodleCore

enum NoodleSettingsTab: Hashable {
    case general, harnesses, heartbeats, security, updates
}

struct NoodleSettingsView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        @Bindable var store = store

        TabView(selection: $store.selectedSettingsTab.animation(.easeInOut(duration: 0.22))) {
            GeneralSettingsView()
                .settingsContentSize()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(NoodleSettingsTab.general)
            HarnessesSettingsView()
                .settingsContentSize()
                .tabItem {
                    Label("Harness", systemImage: "terminal")
                }
                .tag(NoodleSettingsTab.harnesses)
            HeartbeatsSettingsView()
                .settingsContentSize()
                .tabItem {
                    Label("Heartbeat", systemImage: "waveform.path.ecg")
                }
                .tag(NoodleSettingsTab.heartbeats)
            AgentAccessSettingsView()
                .settingsContentSize()
                .tabItem { Label("Security", systemImage: "lock.shield") }
                .tag(NoodleSettingsTab.security)
            UpdatesSettingsView()
                .settingsContentSize()
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(NoodleSettingsTab.updates)
        }
        .modifier(SettingsWindowResizeAnchor())
    }
}

private struct GeneralSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @AppStorage(BotNameStyle.defaultsKey) private var botNameStyle = BotNameStyle.real.rawValue
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showBotDescriptions = true
    @AppStorage(LinkPreviewSettings.timeoutKey) private var linkPreviewTimeout = LinkPreviewSettings.defaultTimeout

    var body: some View {
        Form {
            Section {
                Picker("Generated bot names", selection: $botNameStyle) {
                    ForEach(BotNameStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Show descriptions in the @ name menu", isOn: $showBotDescriptions)
            } footer: {
                Text("Show each bot's public description beside its name. Private backstories are never shown.")
            }
            Section {
                Picker("Link preview timeout", selection: $linkPreviewTimeout) {
                    ForEach(LinkPreviewSettings.timeoutOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
            } footer: {
                Text("Maximum time for new link previews, including images. Unavailable previews remain clickable without a loading spinner.")
            }
            Section {
                Toggle("Keep Mac awake while agents work", isOn: Binding(
                    get: { store.runtime.preventIdleSleepWhileWorking },
                    set: { store.runtime.configurePreventIdleSleepWhileWorking($0) }
                ))
            } footer: {
                Text("Prevents automatic idle sleep only while an agent is working. Closing the lid or choosing Sleep still suspends the Mac.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsWindowResizeAnchor: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.windowResizeAnchor(.top)
        } else {
            content
        }
    }
}

private extension View {
    func settingsContentSize() -> some View {
        frame(width: 580)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HeartbeatsSettingsView: View {
    @Environment(NoodleStore.self) private var store

    private static let suggestedIntervals = [5, 10, 15, 30, 45, 60, 120, 240, 480, 720, 1_440]

    private var intervalOptions: [Int] {
        let current = store.runtime.heartbeatConfiguration.intervalMinutes
        return Array(Set(Self.suggestedIntervals + [current])).sorted()
    }

    var body: some View {
        Form {
            Section {
                Toggle("Wake idle agents", isOn: Binding(
                    get: { store.runtime.heartbeatConfiguration.isEnabled },
                    set: { store.runtime.configureHeartbeats(enabled: $0) }
                ))
                Picker("Wake after", selection: Binding(
                    get: { store.runtime.heartbeatConfiguration.intervalMinutes },
                    set: { store.runtime.configureHeartbeats(intervalMinutes: $0) }
                )) {
                    ForEach(intervalOptions, id: \.self) { minutes in
                        Text(intervalLabel(for: minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!store.runtime.heartbeatConfiguration.isEnabled)
            }
            if !store.agents.isEmpty {
                Section("Bots") {
                    ForEach(store.agents) { agent in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.displayName)
                                if let date = store.runtime.lastHeartbeatDates[agent.id] {
                                    HStack(spacing: 0) {
                                        Text("Last heartbeat ")
                                        Text(date, style: .relative)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("No heartbeat yet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Toggle("Heartbeat for \(agent.displayName)", isOn: Binding(
                                get: { !store.runtime.heartbeatConfiguration.disabledAgentIDs.contains(agent.id) },
                                set: { store.runtime.setHeartbeatEnabled($0, for: agent.id) }
                            ))
                            .labelsHidden()
                        }
                    }
                }
                .disabled(!store.runtime.heartbeatConfiguration.isEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private func intervalLabel(for minutes: Int) -> String {
        switch minutes {
        case 60:
            "1 hour"
        case 1_440:
            "1 day"
        case let value where value.isMultiple(of: 60):
            "\(value / 60) hours"
        case 1:
            "1 minute"
        default:
            "\(minutes) minutes"
        }
    }
}

private struct HarnessesSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @State private var setup = HarnessSetupController(versionChecker: HarnessVersionChecker())
    @State private var showRefreshProgress = false
    @State private var checkingAll = false

    private var isRefreshing: Bool {
        checkingAll || store.runtime.isRefreshingInstallations || !setup.checking.isEmpty || setup.checkingVersions
    }

    var body: some View {
        Form {
            Section {
                ForEach(setup.displayedInstallations) { installation in
                    HarnessInstallationRow(installation: installation,
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

            Section {
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
            }
        }
        .formStyle(.grouped)
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
        guard !checkingAll else { return }
        checkingAll = true
        defer { checkingAll = false }
        await store.runtime.refreshInstallations()
        guard !Task.isCancelled, !store.runtime.isRefreshingInstallations else { return }
        await setup.refresh(store.runtime.installations, discoveryErrors: store.runtime.installationErrors)
        await setup.refreshVersions(store.runtime.installations, forceLatest: forceLatest)
    }
}

private struct HarnessInstallationRow: View {
    let installation: HarnessInstallation
    let liveInstallation: HarnessInstallation?
    let isRefreshing: Bool
    let setup: HarnessSetupController
    let install: () -> Void
    @State private var showsInstallationGuide = false
    @State private var hasCheckedInstallation = false
    @State private var terminalError: String?
    @State private var showsUpdateGuide = false
    @Environment(\.openURL) private var openURL

    private var id: HarnessProvider { installation.provider }

    var body: some View {
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
                    Spacer()
                    Label(statusText, systemImage: statusIcon)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                if let path = installation.executablePath {
                    Text(path)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                if installation.isAvailable {
                    versionDetails
                }
                if let activity = setup.activity[id] {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(activity).font(.caption)
                        Spacer()
                        Button("Cancel") { setup.cancel(id) }
                    }
                }
                if let challenge = setup.challenges[id] {
                    HStack {
                        Text(challenge.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button("Copy Code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(challenge.code, forType: .string)
                        }
                        Button("Open Sign-In Page") { openURL(challenge.url) }
                    }
                    Text("Enter this code on the sign-in page.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if setup.activity[id] == nil {
                    if !installation.isAvailable && setup.snapshots[id] != nil {
                        if showsInstallationGuide, let guide = setup.installationGuide(for: id) {
                            Text(guide.instructions).font(.caption).foregroundStyle(.secondary)
                            if let command = guide.command {
                                Text(command).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button("Copy Command") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(command, forType: .string)
                                    }
                                    Button("Open Terminal") { openTerminal() }
                                }
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
                        } else {
                            Button("Install…") { showsInstallationGuide = true }
                        }
                    } else if setup.authentication[id] == .unauthenticated {
                        Button("Sign In…") {
                            if let liveInstallation, liveInstallation.isAvailable { setup.signIn(liveInstallation) }
                        }
                            .disabled(isRefreshing || liveInstallation?.isAvailable != true)
                    }
                }
            }
        }
        .padding(.vertical, 6)
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
            Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Button("Update Instructions…") { showsUpdateGuide.toggle() }
        if showsUpdateGuide {
            let guide = HarnessVersionPolicy.updateGuide(for: installation)
            Text(guide.instructions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let command = guide.command {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    Button("Open Terminal") { openTerminal() }
                }
            }
            Link("Official Update Guide", destination: guide.documentationURL)
            if let terminalError { Text(terminalError).font(.caption).foregroundStyle(.red) }
        }
    }

    private var statusText: String {
        if setup.activity[id] != nil { return "Setting up" }
        if setup.errors[id] != nil { return "Needs attention" }
        if setup.snapshots[id] == nil { return "Checking…" }
        if !installation.isAvailable { return "Not installed" }
        switch setup.authentication[id] {
        case .authenticated: return "Signed in"
        case .unauthenticated: return "Sign-in required"
        case .notRequired: return "Ready — no sign-in required"
        case nil: return setup.checking.contains(id) ? "Checking sign-in…" : "Installed"
        }
    }

    private var statusIcon: String {
        if setup.errors[id] != nil { return "exclamationmark.triangle" }
        if setup.snapshots[id] == nil { return "ellipsis.circle" }
        if !installation.isAvailable { return "arrow.down.circle" }
        return setup.authentication[id] == .authenticated || setup.authentication[id] == .notRequired
            ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark"
    }

    private var statusColor: Color {
        if setup.errors[id] != nil { return .orange }
        if setup.authentication[id] == .authenticated || setup.authentication[id] == .notRequired { return .green }
        return .secondary
    }
}
