import AppKit
import SwiftUI

public struct CompanionAppsSettingsView: View {
    let store: any BotSettingsHost
    @State private var installations: [CompanionApp: CompanionAppInstallation]
    @State private var opening: CompanionApp?
    @State private var actionError: String?
    @State private var failedApp: CompanionApp?
    private let discoverInstallations: @MainActor () -> [CompanionApp: CompanionAppInstallation]
    private let updateChecker: CompanionUpdateChecker

    @MainActor public init(store: any BotSettingsHost,
                           discoverInstallations: @escaping @MainActor () -> [CompanionApp: CompanionAppInstallation] = { CompanionApp.installedApps() },
                           updateChecker: CompanionUpdateChecker? = nil) {
        self.store = store
        self.discoverInstallations = discoverInstallations
        self.updateChecker = updateChecker ?? .shared
        _installations = State(initialValue: discoverInstallations())
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(CompanionApp.allCases) { app in
                        companionRow(app)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Check Again") {
                    refresh(forceUpdates: true)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .alert(failedApp?.name ?? "Companion App", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            if let app = failedApp, installations[app] == nil {
                Button("View Project") { NSWorkspace.shared.open(app.documentationURL) }
            }
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private func companionRow(_ app: CompanionApp) -> some View {
        let installation = installations[app]
        let updates = app.updateCheckURL(for: installation, update: updateChecker.updates[app]) != nil
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: app.systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(app.name).fontWeight(.semibold)
                    Spacer()
                    SettingsStatusLabel(
                        title: installation == nil ? "Not installed" : "Installed",
                        systemImage: installation == nil ? "arrow.down.circle" : "checkmark.circle.fill",
                        color: installation == nil ? .secondary : .green
                    )
                }
                Text(app.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Group {
                        if let installation {
                            Text(installation.version.map { "Version \($0)" } ?? "Version unavailable")
                                .textSelection(.enabled)
                            if let update = updateChecker.updates[app] {
                                Text("Update available — \(update.displayVersion)").foregroundStyle(.orange)
                            }
                        } else {
                            Text(app.requirements)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(opening == app ? "Opening…" : installation == nil ? "Install" : updates ? "Update" : "Open") {
                        open(app)
                    }
                    .buttonStyle(.link)
                    .disabled(opening != nil)
                    .accessibilityLabel(installation == nil ? "Install \(app.name)" : updates ? "Update \(app.name)" : "Open \(app.name)")
                    .help(installation == nil ? "Open the \(app.name) download page"
                          : updates ? "Open \(app.name) and check for updates" : "Open \(app.name)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh(forceUpdates: Bool = false) {
        store.refreshCompanionSkills()
        let current = discoverInstallations()
        if current != installations { installations = current }
        updateChecker.refresh(current, force: forceUpdates)
    }

    private func open(_ app: CompanionApp) {
        refresh()
        let installed = installations[app] != nil
        let updateCheck = app.updateCheckURL(for: installations[app], update: updateChecker.updates[app])
        opening = app
        Task { @MainActor in
            defer { opening = nil; refresh() }
            do {
                if let updateCheck, let installation = installations[app] {
                    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                    configuration.allowsRunningApplicationSubstitution = false
                    _ = try await NSWorkspace.shared.open([updateCheck], withApplicationAt: installation.applicationURL,
                                                          configuration: configuration)
                    return
                }
                switch app {
                case .browser:
                    if installed { try await store.openCompanionLibrary(.browser) }
                    else { NSWorkspace.shared.open(app.documentationURL) }
                case .computer:
                    if installed { try await store.openCompanionLibrary(.computer) }
                    else { try await store.openComputerDownload() }
                case .applet:
                    if installed { try await store.openCompanionLibrary(.applet) }
                    else { NSWorkspace.shared.open(app.documentationURL) }
                }
            } catch {
                failedApp = app
                actionError = error.localizedDescription
            }
        }
    }
}
