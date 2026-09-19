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


/// The list panel Noodle's Tools settings use: fits a short list, scrolls a long one.
struct SettingsListPanel<Content: View>: View {
    let empty: String
    let isEmpty: Bool
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 80

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isEmpty {
                    Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
                }
                content
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(430, contentHeight))
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
    }
}

private struct SettingsListRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            accessory.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        if divider { Divider().padding(.leading, 14) }
    }
}

@MainActor private func noodletTitle(_ key: String, in library: AppletLibrary) -> String {
    library.entries.first { $0.package.key == key }?.package.manifest.title ?? "Removed Noodlet"
}

private struct AppletPermissionsSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @State private var grants: [String: [String]] = [:]

    var body: some View {
        let keys = grants.keys.sorted { noodletTitle($0, in: library) < noodletTitle($1, in: library) }
        SettingsListPanel(empty: "No noodlets have permissions.", isEmpty: keys.isEmpty) {
            ForEach(keys, id: \.self) { key in
                SettingsListRow(
                    title: noodletTitle(key, in: library),
                    detail: (grants[key] ?? []).compactMap { AppletPermissions.titles[$0] }.joined(separator: ", "),
                    divider: key != keys.last
                ) {
                    Button("Remove") {
                        AppletPermissions.revoke(packageKey: key, defaults: .standard)
                        grants = AppletPermissions.grants(defaults: .standard)
                    }
                }
            }
        }
        .onAppear { grants = AppletPermissions.grants(defaults: .standard) }
    }
}

private struct AppletSecretsSettingsView: View {
    private struct Secret: Identifiable, Equatable {
        let account: String, name: String
        var id: String { account + "\0" + name }
    }
    @ObservedObject var library: AppletLibrary
    @State private var names: [String: [String]] = [:]
    @State private var removing: Secret?

    /// Accounts are a package key followed by .user or .test.
    private func title(_ account: String) -> String {
        let key = account.split(separator: ".").dropLast().joined(separator: ".")
        return noodletTitle(key, in: library) + (account.hasSuffix(".test") ? " (Test)" : "")
    }
    var body: some View {
        let secrets = names.keys.sorted { title($0) < title($1) }
            .flatMap { account in (names[account] ?? []).map { Secret(account: account, name: $0) } }
        SettingsListPanel(empty: "No noodlets have secrets.", isEmpty: secrets.isEmpty) {
            ForEach(secrets) { secret in
                SettingsListRow(title: secret.name, detail: title(secret.account), divider: secret != secrets.last) {
                    Button("Remove…") { removing = secret }
                }
            }
        }
        .onAppear { names = AppletSecrets.shared.names() }
        .confirmationDialog(
            "Remove Secret?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Secret", role: .destructive) {
                if let removing {
                    _ = try? AppletSecrets.shared.perform("delete", name: removing.name, value: nil, account: removing.account)
                }
                names = AppletSecrets.shared.names()
            }
        } message: {
            Text("“\(removing.map { title($0.account) } ?? "")” will need “\(removing?.name ?? "")” entered again.")
        }
    }
}

private struct AppletStorageSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @ObservedObject var runtime: AppletRuntime
    @State private var sizes: [String: Int] = [:]
    @State private var removing: String?

    private func running(_ key: String) -> Bool {
        runtime.sessions.values.contains { $0.package.key == key && $0.isActive }
    }
    var body: some View {
        let keys = sizes.keys.sorted { noodletTitle($0, in: library) < noodletTitle($1, in: library) }
        SettingsListPanel(empty: "No noodlets have saved data.", isEmpty: keys.isEmpty) {
            ForEach(keys, id: \.self) { key in
                SettingsListRow(
                    title: noodletTitle(key, in: library),
                    detail: ByteCountFormatter.string(fromByteCount: Int64(sizes[key] ?? 0), countStyle: .file),
                    divider: key != keys.last
                ) {
                    Button("Remove…") { removing = key }
                        .disabled(running(key))
                        .help(running(key) ? "Close this noodlet before removing its data." : "")
                }
            }
        }
        .onAppear { sizes = AppletStorage.sizes(root: library.root) }
        .confirmationDialog(
            "Remove Saved Data?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Data", role: .destructive) {
                guard let key = removing else { return }
                Task {
                    await AppletStorage.remove(key, root: library.root, defaults: .standard)
                    sizes = AppletStorage.sizes(root: library.root)
                }
            }
        } message: {
            Text("Everything “\(removing.map { noodletTitle($0, in: library) } ?? "")” has saved will be deleted.")
        }
    }
}

private struct AppletSettingsResizeAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.windowResizeAnchor(.top) } else { content }
    }
}
