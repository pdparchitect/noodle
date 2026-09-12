import AppKit
import SwiftUI

struct CompanionAppsSettingsView: View {
    @Environment(NoodleStore.self) private var store
    @State private var installations: [CompanionApp: CompanionAppInstallation]
    @State private var opening: CompanionApp?
    @State private var actionError: String?
    @State private var failedApp: CompanionApp?
    private let discoverInstallations: @MainActor () -> [CompanionApp: CompanionAppInstallation]

    init(discoverInstallations: @escaping @MainActor () -> [CompanionApp: CompanionAppInstallation] = { CompanionApp.installedApps() }) {
        self.discoverInstallations = discoverInstallations
        _installations = State(initialValue: discoverInstallations())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(CompanionApp.allCases) { app in
                        companionRow(app)
                    }
                } footer: {
                    Text("Install companion apps to give your bots more ways to work. Open an installed app to manage it and check for updates.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Check Again", action: refresh)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onAppear(perform: refresh)
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
                    Label(installation == nil ? "Not installed" : "Installed",
                          systemImage: installation == nil ? "arrow.down.circle" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(app.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let installation {
                        Text(installation.version.map { "Version \($0)" } ?? "Version unavailable")
                            .textSelection(.enabled)
                    } else {
                        Text(app.requirements)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(opening == app ? "Opening…" : installation == nil ? "Install…" : "Open") {
                        open(app)
                    }
                    .disabled(opening != nil)
                    .accessibilityLabel(installation == nil ? "Install \(app.name)" : "Open \(app.name)")
                    .help(installation == nil ? "Open the \(app.name) download page" : "Open \(app.name)")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        let current = discoverInstallations()
        if current != installations { installations = current }
    }

    private func open(_ app: CompanionApp) {
        refresh()
        let installed = installations[app] != nil
        opening = app
        Task { @MainActor in
            defer { opening = nil; refresh() }
            do {
                switch app {
                case .computer:
                    if installed { try await store.computers.openLibrary() }
                    else { try await store.computers.openDownload() }
                }
            } catch {
                failedApp = app
                actionError = error.localizedDescription
            }
        }
    }
}
