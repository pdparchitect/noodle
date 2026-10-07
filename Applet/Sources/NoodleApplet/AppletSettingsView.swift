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
    var location: String?
    var divider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if let location {
                    Text(location).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(location)
                }
            }
            Spacer(minLength: 8)
            accessory.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        if divider { Divider().padding(.leading, 14) }
    }
}

@MainActor private func noodletTitle(_ key: String, in entries: [String: LibraryEntry]) -> String {
    entries[key]?.title ?? "Removed Noodlet"
}

/// The library by key, so a long list looks each noodlet up once instead of scanning per row.
@MainActor private func noodletEntries(_ library: AppletLibrary) -> [String: LibraryEntry] {
    Dictionary(library.entries.map { ($0.id, $0) }) { first, _ in first }
}

/// Where the noodlet lives, so noodlets with the same title can be told apart.
@MainActor private func noodletLocation(_ key: String, in entries: [String: LibraryEntry]) -> String? {
    guard let path = entries[key]?.package.url.path else { return nil }
    // The sandbox's own home is the container, so abbreviate against the real one.
    let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

private struct AppletPermissionsSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @State private var grants: [String: [String]] = [:]

    var body: some View {
        let entries = noodletEntries(library)
        let keys = grants.keys.sorted { noodletTitle($0, in: entries) < noodletTitle($1, in: entries) }
        SettingsListPanel(empty: "No noodlets have permissions.", isEmpty: keys.isEmpty) {
            ForEach(keys, id: \.self) { key in
                SettingsListRow(
                    title: noodletTitle(key, in: entries),
                    detail: (grants[key] ?? []).compactMap { AppletPermissions.titles[$0] }.joined(separator: ", "),
                    location: noodletLocation(key, in: entries),
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
    private func title(_ account: String, in entries: [String: LibraryEntry]) -> String {
        let key = account.split(separator: ".").dropLast().joined(separator: ".")
        return noodletTitle(key, in: entries) + (account.hasSuffix(".test") ? " (Test)" : "")
    }
    var body: some View {
        let entries = noodletEntries(library)
        let secrets = names.keys.sorted { title($0, in: entries) < title($1, in: entries) }
            .flatMap { account in (names[account] ?? []).map { Secret(account: account, name: $0) } }
        SettingsListPanel(empty: "No noodlets have secrets.", isEmpty: secrets.isEmpty) {
            ForEach(secrets) { secret in
                SettingsListRow(title: secret.name, detail: title(secret.account, in: entries), divider: secret != secrets.last) {
                    Button("Remove") { removing = secret }
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
            Text("“\(removing.map { title($0.account, in: entries) } ?? "")” will need “\(removing?.name ?? "")” entered again.")
        }
    }
}

private struct AppletStorageSettingsView: View {
    @ObservedObject var library: AppletLibrary
    @ObservedObject var runtime: AppletRuntime
    @ObservedObject private var usage = AppletStorageUsage.shared
    @State private var removing: String?

    private func running(_ key: String) -> Bool {
        runtime.sessions.values.contains { $0.package.key == key && $0.isActive }
    }
    var body: some View {
        let entries = noodletEntries(library)
        let sizes = usage.sizes ?? [:]
        let keys = sizes.keys.sorted { noodletTitle($0, in: entries) < noodletTitle($1, in: entries) }
        SettingsListPanel(
            empty: usage.sizes == nil ? "Calculating…" : "No noodlets have saved data.", isEmpty: keys.isEmpty
        ) {
            ForEach(keys, id: \.self) { key in
                SettingsListRow(
                    title: noodletTitle(key, in: entries),
                    detail: ByteCountFormatter.string(fromByteCount: Int64(sizes[key] ?? 0), countStyle: .file),
                    location: noodletLocation(key, in: entries),
                    divider: key != keys.last
                ) {
                    Button("Remove") { removing = key }
                        .disabled(running(key))
                        .help(running(key) ? "Close this noodlet before removing its data." : "")
                }
            }
        }
        .onAppear { usage.refresh(root: library.root) }
        .confirmationDialog(
            "Remove Saved Data?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Data", role: .destructive) {
                guard let key = removing else { return }
                Task {
                    await AppletStorage.remove(key, root: library.root, defaults: .standard)
                    usage.refresh(root: library.root)
                }
            }
        } message: {
            Text("Everything “\(removing.map { noodletTitle($0, in: entries) } ?? "")” has saved will be deleted.")
        }
    }
}

private struct AppletSettingsResizeAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.windowResizeAnchor(.top) } else { content }
    }
}
