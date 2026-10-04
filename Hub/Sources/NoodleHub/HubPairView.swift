import AppKit
import HubCore
import HubLink
import NoodleBrand
import NoodleRuntimeSettings
import SwiftUI

/// The first launch: the wordmark writes itself, as in Noodle, and Continue brings up pairing
/// the first device in its place.
struct HubWelcomeView: View {
    static let windowID = "welcome"
    static let shownKey = "HubWelcomeShown"

    /// Once, and only for a Hub nobody has paired with yet, such as one from before the welcome.
    static func isNeeded(_ hub: Hub, defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: shownKey) && hub.access.devices.isEmpty
    }

    let hub: Hub

    var body: some View {
        WordmarkWelcome {
            HubPairView(hub: hub)
        }
        .frame(minWidth: 560, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { UserDefaults.standard.set(true, forKey: Self.shownKey) }
    }
}

/// Pair… from the menu: the welcome's wordmark, already written at the top, above the same steps.
struct HubPairWindow: View {
    static let windowID = "pair"

    let hub: Hub
    /// The window scene keeps its state when closed, so each opening starts the steps afresh.
    @State private var opening = UUID()

    var body: some View {
        WordmarkWelcome(lifted: true, gap: 64) {
            HubPairView(hub: hub)
                .id(opening)
        }
        .frame(minWidth: 560, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { opening = UUID() }
    }
}

/// Pairs a new device with the Hub: first whom it is for, an existing user or a new one, then
/// the invitation it joins with.
struct HubPairView: View {
    /// Whom the device is for.
    enum Choice: Hashable { case user(HubUser.ID), new }

    let hub: Hub
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice?
    @State private var user: HubUser?
    @State private var invitation: LinkInvitation?
    @State private var name = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var access: HubAccess { hub.access }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var canContinue: Bool {
        switch choice {
        case .user: true
        case .new: !trimmedName.isEmpty
        case nil: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                if let user, let invitation {
                    heading("Pair \(user.name)’s Device", "Scan the code with Noodle on the device, or send it the link.")
                    HubInvitationView(access: access, user: user, invitation: invitation) {
                        self.invitation = hub.link.invite(user)
                    }
                    .id(invitation.joinKey)
                } else {
                    heading("Pair a Device", "Who is it for?")
                    chooser
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .transition(.opacity)
            Divider()
            HStack {
                if user != nil {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            user = nil
                            invitation = nil
                        }
                    }
                }
                Spacer()
                if user == nil {
                    Button("Continue", action: next)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            guard choice == nil else { return }
            if let first = access.users.first {
                choice = .user(first.id)
            } else {
                choice = .new
                name = NSFullUserName()
            }
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title2.bold())
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// The Hub's users as cards to pick from, and a last card to name a new one.
    private var chooser: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(access.users) { user in
                    card(.user(user.id)) {
                        HubPersonBadge(user: user, access: access, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name).font(.headline)
                            Text(devicesText(access.devices(of: user).count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                card(.new) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                    TextField("New User", text: $name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .focused($nameFocused)
                        .onSubmit(next)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: nameFocused) { _, focused in if focused { choice = .new } }
        .onChange(of: choice) { _, choice in nameFocused = choice == .new }
    }

    private func card(_ option: Choice, @ViewBuilder content: () -> some View) -> some View {
        let selected = choice == option
        return HStack(spacing: 12) {
            content()
            Spacer(minLength: 0)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.quaternary.opacity(selected ? 0.9 : 0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { choice = option }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func devicesText(_ count: Int) -> String {
        switch count {
        case 0: "No devices yet"
        case 1: "1 device"
        default: "\(count) devices"
        }
    }

    /// Adds the new user if that is the choice, then brings up the invitation for whom it is for.
    private func next() {
        guard canContinue else { return }
        do {
            let chosen: HubUser
            switch choice {
            case .user(let id):
                guard let found = access.users.first(where: { $0.id == id }) else { return }
                chosen = found
            case .new:
                chosen = try access.addUser(named: trimmedName)
                choice = .user(chosen.id)
                name = ""
            case nil:
                return
            }
            error = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                user = chosen
                invitation = hub.link.invite(chosen)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
