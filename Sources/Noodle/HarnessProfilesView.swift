import SwiftUI
import NoodleCore

/// Separate logins for one harness, opened from its Settings row.
struct HarnessProfilesView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let installation: HarnessInstallation
    @State private var naming: NamingRequest?
    @State private var name = ""
    @State private var deleting: HarnessProfile?
    @State private var error: String?

    private enum NamingRequest {
        case create, rename(HarnessProfile)
    }

    private var controller: HarnessProfilesController { store.harnessProfiles }
    private var profiles: [HarnessProfile] { controller.profiles(for: installation.provider) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(installation.provider.displayName) Profiles").font(.title2.bold())

                if profiles.isEmpty {
                    Text("No profiles").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                            if index > 0 { Divider() }
                            row(profile)
                        }
                    }
                    .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.11))
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Button("Add Profile…") { name = ""; naming = .create }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await controller.refresh(installation) }
        .onDisappear { controller.cancelAll() }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Profile name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }
                .disabled(ConversationName.error(for: name) != nil)
        }
        .alert("Delete Profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { profile in
            Button("Delete", role: .destructive) { store.deleteHarnessProfile(profile) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { profile in
            Text("“\(profile.displayName)” is signed out of Noodle. Bots using it return to the system profile and restart.")
        }
    }

    private var namingTitle: String {
        if case .rename = naming { return "Rename Profile" }
        return "New Profile"
    }

    private func row(_ profile: HarnessProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).fontWeight(.medium).lineLimit(1)
                    status(profile)
                }
                Spacer(minLength: 8)
                if controller.activity[profile.id] != nil {
                    Button("Cancel") { controller.cancel(profile) }
                } else if controller.authentication[profile.id] != .authenticated, controller.authentication[profile.id] != .notRequired {
                    Button("Sign In…") { controller.signIn(profile, installation: installation) }
                }
                Menu {
                    Button("Rename…") { name = profile.displayName; naming = .rename(profile) }
                    Button("Delete…", role: .destructive) { deleting = profile }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Profile Actions")
            }
            if let challenge = controller.challenges[profile.id] {
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
            }
            if let error = controller.errors[profile.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    @ViewBuilder private func status(_ profile: HarnessProfile) -> some View {
        if let activity = controller.activity[profile.id] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(activity).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            switch controller.authentication[profile.id] {
            case .authenticated:
                SettingsStatusLabel(title: "Signed in", systemImage: "checkmark.circle.fill", color: .green)
            case .unauthenticated:
                SettingsStatusLabel(title: "Sign-in required", systemImage: "person.crop.circle.badge.questionmark", color: .secondary)
            case .notRequired:
                SettingsStatusLabel(title: "Ready", systemImage: "checkmark.circle.fill", color: .green)
            case .managedExternally, nil:
                Text(controller.errors[profile.id] == nil ? "Checking sign-in…" : "Sign-in status unknown")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveName() {
        do {
            switch naming {
            case .create:
                _ = try controller.create(provider: installation.provider, named: name)
                Task { await controller.refresh(installation) }
            case .rename(let profile): try controller.rename(profile, to: name)
            case nil: break
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        naming = nil
    }
}
