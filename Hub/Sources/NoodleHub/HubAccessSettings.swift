import HubCore
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import SwiftUI

/// People the Hub lends harnesses to, each on one plan.
struct HubUsersSettingsView: View {
    let host: HubSettingsHost
    @State private var naming: NamingRequest<HubUser>?
    @State private var removing: HubUser?
    @State private var error: String?

    private var access: HubAccess { host.hub.access }

    var body: some View {
        Form {
            Section {
                if access.users.isEmpty {
                    Text("No users").foregroundStyle(.secondary)
                } else {
                    ForEach(access.users) { user in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(.secondary)
                            Text(user.name).lineLimit(1)
                            Spacer(minLength: 8)
                            Picker("Plan for \(user.name)", selection: Binding(
                                get: { user.plan },
                                set: { id in access.plans.first { $0.id == id }.map { access.move(user, to: $0) } }
                            )) {
                                ForEach(access.plans) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Menu {
                                Button("Rename…") { naming = NamingRequest(.rename(user), name: user.name) }
                                Button("Remove…", role: .destructive) { removing = user }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("User Actions")
                        }
                    }
                }
            } header: {
                Text("Users")
            }
            AccessError(error: error)
            HStack {
                Spacer()
                Button("Add User…") { naming = NamingRequest(.create, name: "") }
            }
        }
        .formStyle(.grouped)
        .namingAlert($naming, create: "New User", rename: "Rename User", field: "Name") { request in
            switch request.kind {
            case .create: try access.addUser(named: request.name)
            case .rename(let user): try access.rename(user, to: request.name)
            }
        } failed: { error = $0 }
        .alert("Remove User?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { user in
            Button("Remove", role: .destructive) { access.remove(user) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { user in
            Text("“\(user.name)” can no longer use this Hub.")
        }
    }
}

/// What each plan lends: a harness's own login or one of its profiles.
struct HubPlansSettingsView: View {
    let host: HubSettingsHost
    @State private var naming: NamingRequest<HubPlan>?
    @State private var deleting: HubPlan?
    @State private var error: String?

    private var access: HubAccess { host.hub.access }

    /// Every login the Hub could lend, in the order the Harness tab lists them.
    private var harnesses: [(harness: HubHarness, name: String)] {
        host.runtime.availableInstallations.flatMap { installation in
            [(HubHarness(provider: installation.provider, profile: nil), "System")]
                + host.harnessProfiles.profiles(for: installation.provider).map {
                    (HubHarness(provider: installation.provider, profile: $0.id), $0.displayName)
                }
        }
    }

    var body: some View {
        Form {
            ForEach(access.plans) { plan in
                Section {
                    if harnesses.isEmpty {
                        Text("No harnesses").foregroundStyle(.secondary)
                    }
                    ForEach(harnesses, id: \.harness) { entry in
                        Toggle(isOn: Binding(
                            get: { plan.harnesses.contains(entry.harness) },
                            set: { access.set(entry.harness, included: $0, in: plan) }
                        )) {
                            HStack(spacing: 10) {
                                HarnessProviderIcon(provider: entry.harness.provider)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.harness.provider.displayName)
                                    Text(entry.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                } header: {
                    HStack {
                        Text(plan.name)
                        Spacer()
                        if !plan.isDefault {
                            Menu {
                                Button("Rename…") { naming = NamingRequest(.rename(plan), name: plan.name) }
                                Button("Delete…", role: .destructive) { deleting = plan }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Plan Actions")
                        }
                    }
                }
            }
            AccessError(error: error)
            HStack {
                Spacer()
                Button("Add Plan…") { naming = NamingRequest(.create, name: "") }
            }
        }
        .formStyle(.grouped)
        .namingAlert($naming, create: "New Plan", rename: "Rename Plan", field: "Plan name") { request in
            switch request.kind {
            case .create: try access.addPlan(named: request.name)
            case .rename(let plan): try access.rename(plan, to: request.name)
            }
        } failed: { error = $0 }
        .alert("Delete Plan?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { plan in
            Button("Delete", role: .destructive) { access.delete(plan) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { plan in
            Text("Users on “\(plan.name)” move to Default.")
        }
    }
}

struct NamingRequest<Item> {
    enum Kind { case create, rename(Item) }
    var kind: Kind
    var name: String
    init(_ kind: Kind, name: String) { self.kind = kind; self.name = name }
}

private struct AccessError: View {
    let error: String?
    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    /// Asks for a name to create or rename with, and reports what `save` throws.
    func namingAlert<Item>(_ request: Binding<NamingRequest<Item>?>, create: String, rename: String, field: String,
                           save: @escaping (NamingRequest<Item>) throws -> Void,
                           failed: @escaping (String?) -> Void) -> some View {
        let title: String
        if case .rename = request.wrappedValue?.kind { title = rename } else { title = create }
        return alert(title, isPresented: Binding(get: { request.wrappedValue != nil },
                                                 set: { if !$0 { request.wrappedValue = nil } })) {
            TextField(field, text: Binding(get: { request.wrappedValue?.name ?? "" },
                                           set: { request.wrappedValue?.name = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let value = request.wrappedValue else { return }
                do { try save(value); failed(nil) } catch { failed(error.localizedDescription) }
            }
            .disabled(ConversationName.error(for: request.wrappedValue?.name ?? "") != nil)
        }
    }
}
