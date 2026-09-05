import SwiftUI
import SuperBotCore

struct SuperBotSettingsView: View {
    var body: some View {
        TabView {
            HarnessesSettingsView()
                .tabItem {
                    Label("Harnesses", systemImage: "terminal")
                }
            UpdatesSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 580, height: 380)
    }
}

private struct HarnessesSettingsView: View {
    @Environment(SuperBotStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if store.runtime.availableInstallations.isEmpty {
                ContentUnavailableView {
                    Label("No Harnesses Detected", systemImage: "terminal")
                } description: {
                    Text("Install a supported harness, then check again.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section("Detected Harnesses") {
                        ForEach(store.runtime.availableInstallations) { installation in
                            HarnessInstallationRow(installation: installation)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                if store.runtime.isRefreshingInstallations {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking for harnesses")
                }
                Button("Check Again") {
                    Task { await store.runtime.refreshInstallations() }
                }
                .disabled(store.runtime.isRefreshingInstallations)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task {
            await store.runtime.refreshInstallations()
        }
    }
}

private struct HarnessInstallationRow: View {
    let installation: HarnessInstallation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: installation.provider.symbolName)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(installation.provider.displayName)
                        .fontWeight(.semibold)
                    Spacer()
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let path = installation.executablePath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
