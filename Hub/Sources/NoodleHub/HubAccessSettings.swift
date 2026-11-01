import HubCore
import HubLink
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleWallpaper
import SwiftUI

/// People the Hub lends harnesses to, each on one plan.
struct HubUsersSettingsView: View {
    let host: HubSettingsHost
    @State private var naming: NamingRequest<HubUser>?
    @State private var removing: HubUser?
    @State private var removingDevice: HubDevice?
    @State private var inviting: Invitation?
    @State private var error: String?

    private struct Invitation: Identifiable {
        let user: HubUser
        let invitation: LinkInvitation
        var id: Data { invitation.joinKey }
    }

    private var access: HubAccess { host.hub.access }

    var body: some View {
        Form {
            Section {
                if access.users.isEmpty {
                    Text("No users").foregroundStyle(.secondary)
                } else {
                    ForEach(access.users) { user in
                        userRow(user)
                        ForEach(access.devices(of: user)) { device in
                            deviceRow(device)
                        }
                    }
                }
            } header: {
                Text("Users")
            }
            AccessError(error: error)
        }
        .formStyle(.grouped)
        .accessFooter("Add User…") { naming = NamingRequest(.create, name: "") }
        .namingAlert($naming, create: "New User", rename: "Rename User", field: "Name") { request in
            switch request.kind {
            case .create: try access.addUser(named: request.name)
            case .rename(let user): try access.rename(user, to: request.name)
            }
        } failed: { error = $0 }
        .alert("Remove User?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { user in
            Button("Remove", role: .destructive) { host.hub.remove(user) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { user in
            Text("“\(user.name)”, their devices and their bots are removed from this Hub.")
        }
        .alert("Remove Device?", isPresented: Binding(get: { removingDevice != nil }, set: { if !$0 { removingDevice = nil } }),
               presenting: removingDevice) { device in
            Button("Remove", role: .destructive) { access.remove(device) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { device in
            Text("“\(device.name)” can no longer reach this Hub until it joins again.")
        }
        .sheet(item: $inviting) { item in
            HubInvitationSheet(access: access, user: item.user, invitation: item.invitation)
        }
    }

    private func deviceRow(_ device: HubDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    if host.hub.link.isConnected(device) {
                        Label("Connected", systemImage: "circle.fill")
                            .labelStyle(ConnectedLabelStyle())
                    } else if let lastSeen = device.lastSeen {
                        Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                    } else {
                        Text("Paired \(device.paired, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Remove") { removingDevice = device }
                .buttonStyle(.link)
        }
        .padding(.leading, 32)
    }

    /// What the user's bots used of their plan's tokens, or until when they wait; nil without a limit.
    private func tokens(of user: HubUser) -> String? {
        _ = host.hub.usage.revision
        let limits = host.hub.tokenLimits
        if let until = limits.holds[user.id] {
            return "Token limit reached until \(until.formatted(date: .abbreviated, time: .shortened))"
        }
        guard let used = limits.used(by: user) else { return nil }
        return "\(used.tokens.formatted(.number.notation(.compactName))) of "
            + "\(used.limit.tokens.formatted(.number.notation(.compactName))) tokens"
    }

    private func userRow(_ user: HubUser) -> some View {
        HStack(spacing: 10) {
            HubPersonBadge(user: user, access: access, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.name).lineLimit(1)
                    ForEach(LinkUserTag.tags(isAdmin: user.isAdmin, isSuspended: user.isSuspended)) { UserTag(tag: $0) }
                }
                if let plan = access.plans.first(where: { $0.id == user.plan }) {
                    Text(([plan.name] + [tokens(of: user)].compactMap { $0 }).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Invite") { inviting = Invitation(user: user, invitation: host.hub.link.invite(user)) }
                .buttonStyle(.link)
                .disabled(user.isSuspended)
            Menu {
                Picker("Plan", selection: Binding(
                    get: { user.plan },
                    set: { id in access.plans.first { $0.id == id }.map { access.move(user, to: $0) } }
                )) {
                    ForEach(access.plans) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Divider()
                Toggle("Suspended", isOn: Binding(
                    get: { user.isSuspended },
                    set: { access.setSuspended($0, for: user) }
                ))
                Toggle("Can Pair Devices", isOn: Binding(
                    get: { user.canPairDevices },
                    set: { access.setCanPairDevices($0, for: user) }
                ))
                Toggle("Admin", isOn: Binding(
                    get: { user.isAdmin },
                    set: { access.setAdmin($0, for: user) }
                ))
                Divider()
                Button("Rename…") { naming = NamingRequest(.rename(user), name: user.name) }
                Button("Remove", role: .destructive) { removing = user }
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

/// The plans, one row each; a plan's harnesses are chosen in its editor.
struct HubPlansSettingsView: View {
    let host: HubSettingsHost
    @State private var editing: Editing?
    @State private var naming: NamingRequest<HubPlan>?

    private struct Editing: Identifiable { let id: HubPlan.ID }
    @State private var error: String?

    private var access: HubAccess { host.hub.access }

    var body: some View {
        Form {
            Section {
                ForEach(access.plans) { plan in
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.stack").font(.title3).foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plan.name).lineLimit(1)
                            Text(summary(plan)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        Button("Edit…") { editing = Editing(id: plan.id) }
                            .buttonStyle(.link)
                        Menu {
                            Button("Duplicate") { duplicate(plan) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Plan Actions")
                    }
                }
            } header: {
                Text("Plans")
            }
            AccessError(error: error)
        }
        .formStyle(.grouped)
        .accessFooter("Add Plan…") { naming = NamingRequest(.create, name: "") }
        .namingAlert($naming, create: "New Plan", rename: "Rename Plan", field: "Plan name") { request in
            if case .create = request.kind { editing = Editing(id: try access.addPlan(named: request.name).id) }
        } failed: { error = $0 }
        .sheet(item: $editing) { item in
            HubPlanEditor(host: host, planID: item.id)
        }
    }

    /// Makes the copy and opens it, to be renamed or changed.
    private func duplicate(_ plan: HubPlan) {
        do {
            editing = Editing(id: try access.duplicate(plan).id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func summary(_ plan: HubPlan) -> String {
        let names = HubPlanEditor.harnesses(host).filter { plan.harnesses.contains($0.harness) }.map(\.title)
        let users = access.users.filter { $0.plan == plan.id }.count
        let lends = names.isEmpty ? "Lends nothing" : "Lends " + names.joined(separator: ", ")
        let tokens = plan.tokenLimit.map { " · \($0.tokens.formatted()) tokens per \($0.periodName)" } ?? ""
        return lends + " · \(users) \(users == 1 ? "user" : "users")" + tokens
    }
}

/// One plan: its name, the harnesses it lends and how many computers and browsers its users keep.
struct HubPlanEditor: View {
    let host: HubSettingsHost
    let planID: HubPlan.ID
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmingDelete = false
    @State private var error: String?
    /// Counts moves to another model, which change no plan, so the list of bots on models not lent is read again.
    @State private var moves = 0
    /// The kinds of computer Noodle Computer on this Mac offers; none while it cannot be reached.
    @State private var computerTypes: [(id: String, name: String)] = []

    private var access: HubAccess { host.hub.access }
    private var plan: HubPlan? { access.plans.first { $0.id == planID } }

    struct Entry {
        let harness: HubHarness
        /// The provider, and the profile when it is not the harness's own login.
        let title: String
        let login: String
    }

    /// Every login the Hub could lend, in the order the Harness tab lists them.
    static func harnesses(_ host: HubSettingsHost) -> [Entry] {
        host.runtime.availableInstallations.flatMap { installation in
            let provider = installation.provider
            return [Entry(harness: HubHarness(provider: provider, profile: nil), title: provider.displayName,
                           login: host.setup.defaultLoginName(provider))]
                + host.harnessProfiles.profiles(for: provider).map {
                    Entry(harness: HubHarness(provider: provider, profile: $0.id),
                          title: "\(provider.displayName) (\($0.displayName))", login: $0.displayName)
                }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let plan {
                VStack(alignment: .leading, spacing: 18) {
                    if plan.isDefault {
                        Text(plan.name).font(.title2.bold())
                    } else {
                        TextField("Plan name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .onSubmit(saveName)
                    }
                    harnessList(plan)
                    unlentList(plan)
                    limitList(plan)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                if plan?.isDefault == false {
                    Button("Delete Plan", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Done") {
                    saveName()
                    if error == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .noodleSheetSizing()
        .onAppear {
            name = plan?.name ?? ""
            host.runtime.refreshCapabilities()
            // The Default logins name their accounts only once their sign-in has been checked.
            let unnamed = host.runtime.availableInstallations.filter { $0.provider.supportsProfiles && host.setup.accounts[$0.provider] == nil }
            if !unnamed.isEmpty { Task { await host.setup.refresh(unnamed) } }
        }
        .task {
            computerTypes = ((try? await host.hub.computers.templates()) ?? []).map { ($0.id, $0.name) }
        }
        .alert("Delete Plan?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let plan { access.delete(plan) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("Users on “\(plan?.name ?? "")” move to Default.")
        }
    }

    /// A row per login, with the models a lent one allows.
    @ViewBuilder private func harnessList(_ plan: HubPlan) -> some View {
        let entries = Self.harnesses(host)
        if entries.isEmpty {
            Text("No harnesses").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.harness) { index, entry in
                        if index > 0 { Divider() }
                        Toggle(isOn: Binding(
                            get: { plan.harnesses.contains(entry.harness) },
                            set: { access.set(entry.harness, included: $0, in: plan) }
                        )) {
                            HStack(spacing: 10) {
                                HarnessProviderIcon(provider: entry.harness.provider)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.harness.provider.displayName)
                                    Text(entry.login).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        if plan.harnesses.contains(entry.harness) {
                            modelList(entry.harness, in: plan)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .planPanel()
        }
    }

    /// The bots of the plan's users on a model it no longer lends, which can't answer until they move to one it does:
    /// each on its own, or all on a harness at once.
    @ViewBuilder private func unlentList(_ plan: HubPlan) -> some View {
        let _ = moves
        let unlent = host.hub.bots.unlentModels().filter { $0.plan == plan.id }
        if !unlent.isEmpty {
            let titles = Dictionary(Self.harnesses(host).map { ($0.harness, $0.title) }) { first, _ in first }
            let harnesses = Array(Set(unlent.map(\.harness)))
                .sorted { (titles[$0] ?? $0.provider.displayName) < (titles[$1] ?? $1.provider.displayName) }
            VStack(spacing: 0) {
                ForEach(Array(harnesses.enumerated()), id: \.element) { index, harness in
                    let bots = unlent.filter { $0.harness == harness }
                    if index > 0 { Divider() }
                    HStack {
                        Label("\(titles[harness] ?? harness.provider.displayName): models not lent", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        if bots.count > 1 { changeModelMenu("Move All to…", bots) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    ForEach(bots) { bot in
                        Divider().padding(.leading, 12)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name)
                                Text([access.users.first { $0.id == bot.owner }?.name, host.modelName(bot.model, on: harness)]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            changeModelMenu("Change Model…", [bot])
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            }
            .planPanel()
        }
    }

    private func changeModelMenu(_ title: String, _ bots: [HubUnlentModel]) -> some View {
        HubChangeModelMenu(host: host, title: title, bots: bots) { failure in
            moves += 1
            error = failure
        }
    }

    /// How many computers and browsers each user on the plan may keep, and tokens their bots may use, blank for any number.
    private func limitList(_ plan: HubPlan) -> some View {
        VStack(spacing: 0) {
            limitRow("Computers per user", limit: plan.computerLimit) { access.setComputerLimit($0, in: plan) }
            Divider()
            computerTypesRow(plan)
            limitRow("Browsers per user", limit: plan.browserLimit) { access.setBrowserLimit($0, in: plan) }
            Divider()
            tokenLimitRow(plan)
        }
        .planPanel()
    }

    /// The kinds of computer the plan's users may make: those Noodle Computer offers, and any the plan names that it no longer does.
    @ViewBuilder private func computerTypesRow(_ plan: HubPlan) -> some View {
        let allowed = plan.computerTypes
        let ids = computerTypes.map(\.id) + (allowed ?? []).subtracting(computerTypes.map(\.id)).sorted()
        if !ids.isEmpty {
            HStack {
                Text("Computer types")
                Spacer()
                HubChoicePicker(
                    every: "All types",
                    choices: ids.map { id in (id, computerTypes.first { $0.id == id }?.name ?? id) },
                    allowed: allowed,
                    set: { access.setComputerTypes($0, in: plan) }
                )
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        }
    }

    /// Tokens per user, and once there is a limit, the period it counts them over.
    private func tokenLimitRow(_ plan: HubPlan) -> some View {
        let limit = plan.tokenLimit
        let set = { (tokens: Int?, length: Int?, unit: HubTokenLimit.Unit?) in
            access.setTokenLimit((tokens ?? limit?.tokens).map {
                HubTokenLimit(tokens: $0, length: length ?? limit?.length ?? 1, unit: unit ?? limit?.unit ?? .weeks)
            }, in: plan)
        }
        return HStack(spacing: 8) {
            Text("Tokens per user")
            Spacer()
            TextField("Tokens per user", value: Binding(get: { limit?.tokens }, set: { tokens in
                if let tokens { set(tokens, nil, nil) } else { access.setTokenLimit(nil, in: plan) }
            }), format: .number, prompt: Text("No limit"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
            if let limit {
                Text("per")
                TextField("Period", value: Binding(get: { limit.length }, set: { set(nil, $0, nil) }), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Picker("Period", selection: Binding(get: { limit.unit }, set: { set(nil, nil, $0) })) {
                    ForEach(HubTokenLimit.Unit.allCases, id: \.self) { Text($0.name(count: limit.length)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func limitRow(_ title: String, limit: Int?, set: @escaping (Int?) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: Binding(get: { limit }, set: set), format: .number, prompt: Text("No limit"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// A link naming the models the harness lends, opening a popover to choose them.
    @ViewBuilder private func modelList(_ harness: HubHarness, in plan: HubPlan) -> some View {
        let known = host.runtime.models(for: harness.provider.rawValue)
        let allowed = plan.models[harness]
        let ids = known.map(\.id) + (allowed ?? []).subtracting(known.map(\.id)).sorted()
        if !ids.isEmpty {
            HubChoicePicker(
                every: "All models",
                choices: ids.map { id in (id, known.first { $0.id == id }?.displayName ?? id) },
                allowed: allowed,
                set: { access.setModels($0, for: harness, in: plan) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 10)
        }
    }

    private func saveName() {
        guard let plan, !plan.isDefault, name != plan.name else { error = nil; return }
        do {
            try access.rename(plan, to: name)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension View {
    /// The rounded box the plan editor groups its rows in.
    func planPanel() -> some View {
        background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.11))
            }
    }
}

/// Every choice, or only those ticked; the last one ticked stays so the plan still includes something.
private struct HubChoicePicker: View {
    /// "All models", or "All types".
    let every: String
    let choices: [(id: String, name: String)]
    let allowed: Set<String>?
    let set: (Set<String>?) -> Void
    @State private var showing = false

    private var title: String {
        guard let allowed else { return every }
        return choices.filter { allowed.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    var body: some View {
        Button(title) { showing = true }
            .buttonStyle(.link)
            .controlSize(.small)
            .lineLimit(1)
            .truncationMode(.tail)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(every, isOn: Binding(
                        get: { allowed == nil },
                        set: { set($0 ? nil : Set(choices.map(\.id))) }
                    ))
                    Divider()
                    ForEach(choices, id: \.id) { choice in
                        Toggle(choice.name, isOn: Binding(
                            get: { allowed?.contains(choice.id) ?? true },
                            set: { on in
                                let current = allowed ?? Set(choices.map(\.id))
                                set(on ? current.union([choice.id]) : current.subtracting([choice.id]))
                            }
                        ))
                        .disabled(allowed == nil || allowed == [choice.id])
                    }
                }
                .toggleStyle(.checkbox)
                .padding(14)
                .frame(minWidth: 180, alignment: .leading)
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

extension View {
    /// The action below a tab's list, set apart like the Companions tab's Check Again.
    func accessFooter(_ title: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            self
            Divider()
            HStack {
                Spacer()
                Button(title, action: action)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
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

/// A small green dot before the text.
struct ConnectedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(.green)
            configuration.title
        }
    }
}

/// The picture someone chose on their device, or their initials on a colour, as their devices show them.
struct HubPersonBadge: View {
    let user: HubUser
    let access: HubAccess
    let size: CGFloat
    @State private var image: Data?

    var body: some View {
        let avatar = user.avatar ?? .standard(for: user.id)
        IconBadge(appearance: IconAppearance(symbol: avatar.symbol, colour: avatar.colour, image: image),
                  symbol: "person.fill", size: size, showsShadow: false, initials: LinkAvatar.initials(of: user.name))
            .task(id: user.avatar?.imageDigest) { image = access.picture(of: user.id) }
    }
}

/// Admin in the accent colour or Suspended in orange, beside a person's name in Users.
private struct UserTag: View {
    let tag: LinkUserTag

    var body: some View {
        Text(tag.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tag == .admin ? Color.accentColor : Color.orange, in: Capsule())
            .fixedSize()
    }
}
