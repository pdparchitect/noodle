import Foundation
import HubLink
import SwiftTUICLI
import TerminalCore

/// The screen a route shows over the list. Escape goes back.
struct Screen: View {
    let route: Route
    let hubs: TerminalHubs
    let app: AppState

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .join:
            JoinView(hubs: hubs, canCancel: true, done: { app.pop() })
        case .hubs:
            HubsView(hubs: hubs, app: app)
        case .archived:
            ArchivedView(hubs: hubs, app: app)
        case .pairDevice(let id):
            if let chats = chats(id) { PairDeviceView(chats: chats) } else { gone }
        case .users(let id):
            if let chats = chats(id) { UsersView(chats: chats, app: app) } else { gone }
        case .user(let id, let user):
            if let chats = chats(id) { UserView(users: UsersStore.users(for: chats), userID: user, app: app) } else { gone }
        case .newBot:
            BotEditor(hubs: hubs, app: app, editing: nil)
        case .editBot(let key):
            if let row = hubs.row(key), let bot = row.thread.bot { BotEditor(hubs: hubs, app: app, editing: (row.chats, bot)) } else { gone }
        case .newGroup:
            GroupEditor(hubs: hubs, app: app, editing: nil)
        case .editGroup(let key):
            if let row = hubs.row(key), let group = row.thread.group { GroupEditor(hubs: hubs, app: app, editing: (row.chats, group)) } else { gone }
        case .tools(let key, let kind):
            if let row = hubs.row(key), let bot = row.thread.bot { ToolsView(chats: row.chats, bot: bot, kind: kind, app: app) } else { gone }
        case .sharing(let key):
            if let row = hubs.row(key), let bot = row.thread.bot { SharingView(chats: row.chats, bot: bot, app: app) } else { gone }
        }
    }

    private func chats(_ id: ObjectIdentifier) -> HubChats? { hubs.chats.first { $0.id == id } }

    private var gone: some View { Text("This is no longer on the Hub. Press Escape to go back.").foregroundStyle(.secondary) }
}

/// A screen's title, and how to leave it.
struct ScreenTitle: View {
    let title: String

    var body: some View {
        HStack {
            Text(title).bold()
            Spacer()
            Text("Escape goes back").foregroundStyle(.secondary)
        }
        .padding(.bottom, 1)
    }
}

// MARK: Hubs

/// Every Hub this terminal joined: whether it answers, and what can be done on it.
struct HubsView: View {
    let hubs: TerminalHubs
    let app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ScreenTitle(title: "Hubs")
            ForEach(hubs.chats) { chats in
                HubRow(hubs: hubs, chats: chats, app: app)
            }
            Button("Join Another Hub…") { app.push(.join) }
        }
    }
}

private struct HubRow: View {
    let hubs: TerminalHubs
    let chats: HubChats
    let app: AppState

    var body: some View {
        let status = chats.pairing.status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                Text(chats.hubName).bold()
                if chats.isConnected { Text("Connected").foregroundStyle(.secondary) } else { Text("Not connected").foregroundStyle(.red) }
            }
            Text([status?.userName ?? chats.pairing.hub?.userName, status.map { "\($0.planName) plan" },
                  status?.isAdmin == true ? "Admin" : nil].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            if let error = chats.pairing.error ?? chats.error { Text(error).foregroundStyle(.red) }
            HStack(spacing: 2) {
                if hubs.spaces.count > 1 {
                    Button("Show Its Space") {
                        hubs.space = .hub(chats.id)
                        app.path = []
                    }
                }
                if status?.canPairDevices == true { Button("Pair Another Device…") { app.push(.pairDevice(chats.id)) } }
                if status?.isAdmin == true { Button("Users…") { app.push(.users(chats.id)) } }
                Button("Leave…") {
                    app.confirming = Confirmation(title: "Leave \(chats.hubName)?",
                        message: "This Mac stops showing its bots and groups. They stay on the Hub, and you can join again with a new invitation.",
                        button: "Leave") {
                        hubs.leave(chats)
                        if hubs.chats.isEmpty { app.path = [] }
                    }
                }
            }
            if chats.mutesGroups {
                Picker("Groups notify", selection: Binding(
                    get: { status?.groupNotifications ?? .all },
                    set: { level in app.run { try await chats.setGroupNotifications(level) } })) {
                    Text("All Messages").tag(LinkNotifications.all)
                    if chats.notifiesMentions { Text("Mentions Only").tag(LinkNotifications.mentions) }
                }
            }
        }
    }
}

/// A one-time invitation for another of the person's devices.
struct PairDeviceView: View {
    let chats: HubChats
    @State private var invitation: LinkInvitation?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ScreenTitle(title: "Pair Another Device with \(chats.hubName)")
            if let invitation {
                Text("On the other device, join a Hub and paste this link. It works once, until \(invitation.expires.formatted(date: .omitted, time: .shortened)).")
                Text(invitation.url().absoluteString)
                Button("Copy Link") {
                    NSPasteboardWriter.copy(invitation.url().absoluteString)
                }
            } else if let problem {
                Text(problem).foregroundStyle(.red)
            } else {
                Text("Asking the Hub…").foregroundStyle(.secondary)
            }
        }
        .task {
            do { invitation = try await chats.pairing.invite() } catch { problem = error.localizedDescription }
        }
    }
}

/// Bots and groups taken off the list, to bring back.
struct ArchivedView: View {
    let hubs: TerminalHubs
    let app: AppState

    var body: some View {
        let archived = hubs.chats.flatMap { chats in chats.archivedThreads.map { TerminalHubs.Row(chats: chats, thread: $0) } }
        VStack(alignment: .leading, spacing: 1) {
            ScreenTitle(title: "Archived")
            if archived.isEmpty { Text("Nothing is archived.").foregroundStyle(.secondary) }
            ForEach(archived) { row in
                HStack(spacing: 1) {
                    Image(data: Pictures.png(for: row.thread, in: row.chats)).resizable().scaledToFit().frame(width: 4, height: 2)
                    Text(row.thread.name)
                    if hubs.chats.count > 1 { Text(row.chats.hubName).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Bring Back") { app.run { try await row.chats.setArchived(false, row.thread) } }
                }
            }
        }
    }
}

// MARK: Users

/// Each Hub's users, kept while the app runs so a user's screen and the list agree.
@MainActor enum UsersStore {
    private static var stores: [ObjectIdentifier: HubUsers] = [:]

    static func users(for chats: HubChats) -> HubUsers {
        if let kept = stores[chats.id] { return kept }
        let made = HubUsers(pairing: chats.pairing)
        stores[chats.id] = made
        return made
    }
}

/// Everyone on a Hub, for its admins.
struct UsersView: View {
    let chats: HubChats
    let app: AppState
    @State private var name = ""
    @FocusState private var focusedUser: UUID?

    var body: some View {
        let users = UsersStore.users(for: chats)
        VStack(alignment: .leading, spacing: 1) {
            ScreenTitle(title: "Users of \(chats.hubName)")
            if let error = users.error { Text(error).foregroundStyle(.red) }
            Text("Up and Down move between people, Return opens one. Back here, Tab returns to them.").foregroundStyle(.secondary)
            // A button each, so Return opens the one focused; Up and Down move between them.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(users.users) { user in
                    Button {
                        app.push(.user(chats.id, user.id))
                    } label: {
                        Text(([user.name, users.planName(of: user)] + user.tags.map(\.title)).compactMap { $0 }.joined(separator: " · "))
                    }
                    .focused($focusedUser, equals: user.id)
                }
            }
            .onKeyPress(.arrowDown) { _ in move(1, in: users.users) }
            .onKeyPress(.arrowUp) { _ in move(-1, in: users.users) }
            HStack(spacing: 1) {
                TextField("New user's name", text: $name).onSubmit { add(users) }
                Button("Add") { add(users) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task { await users.load() }
        // Once the buttons are there: focus asked for before they are drawn goes nowhere.
        .onChange(of: users.users.map(\.id), initial: true) { _, ids in
            if focusedUser.map(ids.contains) != true { focusedUser = ids.first }
        }
    }

    private func move(_ step: Int, in users: [LinkUser]) -> KeyPressResult {
        guard let index = users.firstIndex(where: { $0.id == focusedUser }) else { return .ignored }
        let next = index + step
        guard users.indices.contains(next) else { return .ignored }
        focusedUser = users[next].id
        return .handled
    }

    private func add(_ users: HubUsers) {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        name = ""
        Task {
            if let user = await users.add(named: typed) { app.push(.user(chats.id, user.id)) }
        }
    }
}

/// One user: their name, plan and devices. Admins are changed on the Hub itself.
struct UserView: View {
    let users: HubUsers
    let userID: UUID
    let app: AppState
    @State private var name = ""
    @State private var invitation: LinkInvitation?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let user = users.users.first(where: { $0.id == userID }) {
                ScreenTitle(title: user.name)
                if let error = users.error { Text(error).foregroundStyle(.red) }
                if user.isAdmin {
                    Text("An admin. Only the Hub changes admins.").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 1) {
                        TextField("Name", text: $name).onSubmit { rename(user) }
                        Button("Rename") { rename(user) }
                    }
                    Picker("Plan", selection: Binding(get: { user.plan }, set: { plan in Task { await users.move(user, to: plan) } })) {
                        ForEach(users.plans) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Can pair devices", isOn: Binding(get: { user.canPairDevices },
                                                             set: { on in Task { await users.setCanPairDevices(on, for: user) } }))
                    Toggle("Suspended", isOn: Binding(get: { user.isSuspended }, set: { on in Task { await users.setSuspended(on, for: user) } }))
                    Text("Suspended stops their Hub bots and blocks their devices; turning it off brings everything back.")
                        .foregroundStyle(.secondary)
                    Button("Invite a Device…") { Task { invitation = await users.invite(user) } }
                    if let invitation {
                        Text("On \(user.name)'s device, join a Hub and paste this link. It works once.")
                        Text(invitation.url().absoluteString)
                        Button("Copy Link") { NSPasteboardWriter.copy(invitation.url().absoluteString) }
                    }
                }
                Text("Devices").bold().padding(.top, 1)
                if user.devices.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(user.devices) { device in
                    HStack(spacing: 1) {
                        Text(device.name)
                        Text(device.isConnected ? "Connected" : device.lastSeen.map { "Seen \($0.formatted(.relative(presentation: .named)))" } ?? "")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !user.isAdmin {
                            Button("Remove") {
                                app.confirming = Confirmation(title: "Remove \(device.name)?",
                                    message: "It can no longer reach the Hub until it joins again.", button: "Remove") {
                                    await users.remove(device)
                                }
                            }
                        }
                    }
                }
                if !user.isAdmin {
                    Button("Remove \(user.name)…") {
                        app.confirming = Confirmation(title: "Remove \(user.name)?",
                            message: "Their bots, groups and devices are removed from the Hub.", button: "Remove") {
                            await users.remove(user)
                            app.pop()
                        }
                    }
                    .padding(.top, 1)
                }
            } else {
                Text("This user is no longer on the Hub.").foregroundStyle(.secondary)
            }
        }
        .onAppear { name = users.users.first { $0.id == userID }?.name ?? "" }
    }

    private func rename(_ user: LinkUser) {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != user.name else { return }
        Task { await users.rename(user, to: typed) }
    }
}

// MARK: Bots and groups

/// Makes a bot on a Hub, or edits one: who it is, the harness and model it runs on, and its picture.
struct BotEditor: View {
    let hubs: TerminalHubs
    let app: AppState
    let editing: (chats: HubChats, bot: LinkBot)?
    @State private var hubIndex = 0
    @State private var draft = LinkBotDraft(name: "", provider: "", avatarSymbolName: "sparkles",
                                            avatarColorIndex: Int.random(in: 0..<Pictures.colourNames.count))
    @State private var loaded = false
    @State private var saving = false
    @State private var problem: String?
    @FocusState private var nameFocused: Bool?

    private var chats: HubChats? { editing?.chats ?? (hubs.chats.indices.contains(hubIndex) ? hubs.chats[hubIndex] : nil) }
    private var harnesses: [LinkHarness] { chats?.harnesses(keeping: editing?.bot.draft) ?? [] }
    private var harness: LinkHarness? { harnesses.first { $0.provider == draft.provider && $0.profile == draft.profile } }

    /// The models the harness offers, plus the bot's current one if the plan no longer lends it.
    private var models: [LinkModel] {
        var models = harness?.models ?? []
        if let model = draft.model, !models.contains(where: { $0.id == model }) { models.insert(LinkModel(id: model, name: model), at: 0) }
        return models
    }

    private var efforts: [LinkEffort] { models.first { $0.id == draft.model }?.efforts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ScreenTitle(title: editing.map { "Edit \($0.bot.draft.name)" } ?? "New Bot")
            HStack(alignment: .top, spacing: 2) {
                Image(data: Pictures.png(for: [draft])).resizable().scaledToFit().frame(width: 8, height: 4)
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Name", text: $draft.name).focused($nameFocused, equals: true)
                    TextField("Description", text: $draft.publicDescription)
                }
            }
            Text("Backstory: who this bot is, its role, tone or priorities").foregroundStyle(.secondary)
            TextEditor(text: $draft.backstory).frame(height: 5)
            if editing == nil, hubs.chats.count > 1 {
                Picker("Hub", selection: $hubIndex) {
                    ForEach(Array(hubs.chats.enumerated()), id: \.offset) { index, chats in Text(chats.hubName).tag(index) }
                }
            }
            if harnesses.isEmpty {
                Text("Your plan lends no harnesses.").foregroundStyle(.secondary)
            } else {
                Picker("Harness", selection: Binding(
                    get: { harnesses.firstIndex { $0.provider == draft.provider && $0.profile == draft.profile } ?? -1 },
                    set: { index in choose(harnesses.indices.contains(index) ? harnesses[index] : nil) })) {
                    if harness == nil { Text("Choose").tag(-1) }
                    ForEach(Array(harnesses.enumerated()), id: \.offset) { index, lent in
                        Text(lent.profileName.map { "\(lent.providerName) · \($0)" } ?? lent.providerName).tag(index)
                    }
                }
                if let harness, !models.isEmpty {
                    Picker("Model", selection: Binding(get: { draft.model }, set: { draft.setModel($0, on: harness) })) {
                        if !harness.restrictsModels || draft.model == nil {
                            Text(harness.restrictsModels ? "Choose" : "Default").tag(String?.none)
                        }
                        ForEach(models) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
                if !efforts.isEmpty {
                    Picker("Effort", selection: $draft.reasoningEffort) {
                        Text("Default").tag(String?.none)
                        ForEach(efforts) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
            }
            Picker("Colour", selection: Binding(get: { Pictures.colourIndex(draft.avatarColorIndex) }, set: { draft.avatarColorIndex = $0 })) {
                ForEach(Array(Pictures.colourNames.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
            }
            TextField("Symbol, such as sparkles or brain.head.profile", text: Binding(
                get: { draft.avatarSymbolName ?? "" }, set: { draft.avatarSymbolName = $0.isEmpty ? nil : $0 }))
            if draft.hasPicture {
                Button("Use Symbol Instead of Picture") { draft.removePicture() }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack(spacing: 2) {
                Button(saving ? "Saving…" : editing == nil ? "Create" : "Save") { save() }
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.provider.isEmpty
                              || (harness?.restrictsModels == true && draft.model == nil))
                Button("Cancel") { app.pop() }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let editing { draft = editing.bot.draft }
            if case .hub(let id) = hubs.space, let index = hubs.chats.firstIndex(where: { $0.id == id }) { hubIndex = index }
            nameFocused = true
        }
    }

    private func choose(_ chosen: LinkHarness?) {
        draft.provider = chosen?.provider ?? ""
        draft.profile = chosen?.profile
        draft.reasoningEffort = nil
        draft.setModel(chosen?.initialModel, on: chosen)
        draft.model = chosen?.initialModel
    }

    private func save() {
        guard let chats else { return }
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                if let editing { try await chats.update(editing.bot, to: draft) } else { try await chats.create(draft) }
                app.pop()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Makes a group of a Hub's bots, or edits one: its name, description and bots.
struct GroupEditor: View {
    let hubs: TerminalHubs
    let app: AppState
    let editing: (chats: HubChats, group: LinkGroup)?
    @State private var hubIndex = 0
    @State private var draft = LinkGroupDraft(name: "", botIDs: [])
    @State private var loaded = false
    @State private var saving = false
    @State private var problem: String?
    @FocusState private var nameFocused: Bool?

    private var chats: HubChats? { editing?.chats ?? (hubs.chats.indices.contains(hubIndex) ? hubs.chats[hubIndex] : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ScreenTitle(title: editing.map { "Edit \($0.group.draft.name)" } ?? "New Group")
            TextField("Name", text: $draft.name).focused($nameFocused, equals: true)
            TextField("Description", text: $draft.publicDescription)
            if editing == nil, hubs.chats.count > 1 {
                Picker("Hub", selection: Binding(get: { hubIndex }, set: { hubIndex = $0; draft.botIDs = [] })) {
                    ForEach(Array(hubs.chats.enumerated()), id: \.offset) { index, chats in Text(chats.hubName).tag(index) }
                }
            }
            Text("Bots").bold()
            ForEach((chats?.bots ?? []).filter { $0.archivedAt == nil && $0.owner == nil }) { bot in
                Toggle(bot.draft.name, isOn: Binding(
                    get: { draft.botIDs.contains(bot.id) },
                    set: { on in
                        if on { if !draft.botIDs.contains(bot.id) { draft.botIDs.append(bot.id) } } else { draft.botIDs.removeAll { $0 == bot.id } }
                    }))
            }
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack(spacing: 2) {
                Button(saving ? "Saving…" : editing == nil ? "Create" : "Save") { save() }
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.botIDs.isEmpty)
                Button("Cancel") { app.pop() }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let editing { draft = editing.group.draft }
            if case .hub(let id) = hubs.space, let index = hubs.chats.firstIndex(where: { $0.id == id }) { hubIndex = index }
            nameFocused = true
        }
    }

    private func save() {
        guard let chats else { return }
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                if let editing { try await chats.updateGroup(editing.group, to: draft) } else { try await chats.createGroup(draft) }
                app.pop()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The tool connections, computers or browsers on the Hub, each with whether the bot may use it.
struct ToolsView: View {
    let chats: HubChats
    let bot: LinkBot
    let kind: HubChats.Tool
    let app: AppState

    private var title: String {
        switch kind {
        case .connection: "Tools"
        case .computer: "Computers"
        case .browser: "Browsers"
        }
    }

    var body: some View {
        let tools = chats.tools(kind, for: bot)
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "\(title) for \(bot.draft.name)")
            if tools.isEmpty {
                Text("You have no \(title.lowercased()) on \(chats.hubName). Add them in Noodle on your Mac or phone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(tools, id: \.id) { tool in
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(tool.name, isOn: Binding(get: { tool.assigned }, set: { on in
                        app.run { try await chats.setAssigned(on, kind, tool.id, for: bot) }
                    }))
                    if let detail = tool.detail, !detail.isEmpty { Text("  " + detail).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// Who else on the Hub can talk to the bot.
struct SharingView: View {
    let chats: HubChats
    let bot: LinkBot
    let app: AppState
    @State private var people: [LinkPerson]?
    @State private var problem: String?

    var body: some View {
        let sharedWith = chats.bots.first { $0.id == bot.id }?.sharedWith ?? bot.sharedWith
        VStack(alignment: .leading, spacing: 0) {
            ScreenTitle(title: "Share \(bot.draft.name)")
            Text("They can talk with it; only you can change it.").foregroundStyle(.secondary).padding(.bottom, 1)
            if let problem { Text(problem).foregroundStyle(.red) }
            if let people {
                if people.isEmpty { Text("Nobody else is on \(chats.hubName).").foregroundStyle(.secondary) }
                ForEach(people) { person in
                    Toggle(person.name, isOn: Binding(get: { sharedWith.contains(person.id) }, set: { on in
                        app.run { try await chats.setShared(on, bot, with: person.id) }
                    }))
                }
            } else if problem == nil {
                Text("Asking the Hub…").foregroundStyle(.secondary)
            }
        }
        .task {
            do { people = try await chats.people() } catch { problem = error.localizedDescription }
        }
    }
}

import AppKit

enum NSPasteboardWriter {
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
