import AppKit
import SwiftUI
import NoodleSettingsUI

enum AppletSettingsTab: Hashable { case general, permissions, secrets, storage, updates }

struct AppletSettingsView: View {
    @ObservedObject var background: AppletBackgroundStore
    @ObservedObject var library: AppletLibrary
    @ObservedObject var runtime: AppletRuntime
    @State private var selection: AppletSettingsTab = .general
    @ObservedObject private var updater = AppletUpdater.shared

    var body: some View {
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) {
            AppletGeneralSettingsView(background: background)
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(AppletSettingsTab.general)
            AppletPermissionsSettingsView(library: library)
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
                .tag(AppletSettingsTab.permissions)
            AppletSecretsSettingsView(library: library)
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Secrets", systemImage: "key") }
                .tag(AppletSettingsTab.secrets)
            AppletStorageSettingsView(library: library, runtime: runtime)
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(AppletSettingsTab.storage)
            AppletUpdatesSettingsView()
                .frame(width: 580)
                .fixedSize(horizontal: false, vertical: true)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(AppletSettingsTab.updates)
        }
        .modifier(AppletSettingsResizeAnchor())
        .settingsScrollIndicators(selection: selection)
        .background(SettingsTabBadge(counts: ["Update": updater.availableVersion == nil ? 0 : 1]))
        // Check on opening Settings so the tab is badged before it is selected.
        .onAppear { updater.probeForUpdate() }
    }
}

private struct AppletGeneralSettingsView: View {
    @ObservedObject var background: AppletBackgroundStore
    @State private var changingBackground = false

    var body: some View {
        Form {
            CompanionVisibilitySettings()
            Section {
                LabeledContent("Library background") {
                    Button("Change Background…") { changingBackground = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $changingBackground) {
            AppletBackgroundSheet(store: background)
        }
    }
}

private struct AppletPermissionsSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @State private var grants: [String: [String]] = [:]

    private func title(_ key: String) -> String {
        noodletTitle(key, in: library)
    }
    var body: some View {
        Form {
            Section {
                if grants.isEmpty {
                    Text("No noodlets have permissions.").foregroundStyle(.secondary)
                }
                ForEach(grants.keys.sorted { title($0) < title($1) }, id: \.self) { key in
                    LabeledContent {
                        Button("Remove") {
                            AppletPermissions.revoke(packageKey: key, defaults: .standard)
                            grants = AppletPermissions.grants(defaults: .standard)
                        }
                    } label: {
                        Text(title(key))
                        Text((grants[key] ?? []).compactMap { AppletPermissions.titles[$0] }.joined(separator: ", "))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { grants = AppletPermissions.grants(defaults: .standard) }
    }
}

@MainActor private func noodletTitle(_ key: String, in library: AppletLibrary) -> String {
    library.entries.first { $0.package.key == key }?.package.manifest.title ?? "Removed Noodlet"
}

private struct AppletSecretsSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @State private var names: [String: [String]] = [:]

    /// Accounts are a package key followed by .user or .test.
    private func title(_ account: String) -> String {
        let key = String(account.split(separator: ".").dropLast().joined(separator: "."))
        return noodletTitle(key, in: library) + (account.hasSuffix(".test") ? " (Test)" : "")
    }
    var body: some View {
        Form {
            if names.isEmpty {
                Section { Text("No noodlets have secrets.").foregroundStyle(.secondary) }
            }
            ForEach(names.keys.sorted { title($0) < title($1) }, id: \.self) { account in
                Section(title(account)) {
                    ForEach(names[account] ?? [], id: \.self) { name in
                        LabeledContent(name) {
                            Button("Remove") {
                                _ = try? AppletSecrets.shared.perform("delete", name: name, value: nil, account: account)
                                names = AppletSecrets.shared.names()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { names = AppletSecrets.shared.names() }
    }
}

private struct AppletStorageSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @ObservedObject var runtime: AppletRuntime
    @State private var sizes: [String: Int] = [:]

    private func running(_ key: String) -> Bool {
        runtime.sessions.values.contains { $0.package.key == key && $0.isActive }
    }
    var body: some View {
        Form {
            Section {
                if sizes.isEmpty {
                    Text("No noodlets have saved data.").foregroundStyle(.secondary)
                }
                ForEach(sizes.keys.sorted { noodletTitle($0, in: library) < noodletTitle($1, in: library) }, id: \.self) { key in
                    LabeledContent {
                        Button("Remove") {
                            Task {
                                await AppletStorage.remove(key, root: library.root, defaults: .standard)
                                sizes = AppletStorage.sizes(root: library.root)
                            }
                        }
                        .disabled(running(key))
                        .help(running(key) ? "Close this noodlet before removing its data." : "")
                    } label: {
                        Text(noodletTitle(key, in: library))
                        Text(ByteCountFormatter.string(fromByteCount: Int64(sizes[key] ?? 0), countStyle: .file))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { sizes = AppletStorage.sizes(root: library.root) }
    }
}

private struct AppletSettingsResizeAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.windowResizeAnchor(.top) } else { content }
    }
}
