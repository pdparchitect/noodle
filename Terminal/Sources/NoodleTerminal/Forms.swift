import Foundation
import HubLink
import TerminalCore
import TerminalScreen

/// Making and changing bots and groups, a field or a list at a time in the message field; and the Hubs, their
/// devices and their users.
extension App {
    static let colourNames = ["Blue", "Purple", "Orange", "Mint", "Indigo", "Pink"]

    /// Bots may store any integer; it wraps onto the palette.
    static func colourIndex(_ colour: Int) -> Int { Int(colour.magnitude % UInt(colourNames.count)) }

    /// The Hub a new bot or group goes on: the only one, the one shown, or the one chosen.
    private func chooseHub(for title: String) async -> HubChats? {
        let all = hubs.chats
        guard all.count > 1 else { return all.first }
        let shown: ObjectIdentifier? = if case .hub(let id) = hubs.space { id } else { row?.chats.id }
        guard let item = await choose("Hubs for the \(title.lowercased())", {
            all.enumerated().map { Picker.Item(id: "\($0.offset)", label: $0.element.hubName, current: $0.element.id == shown) }
        }), let index = Int(item.id), all.indices.contains(index) else { return nil }
        return all[index]
    }

    func makeNew(_ kind: String) {
        Task {
            var kind = kind.lowercased()
            if kind.isEmpty {
                guard let item = await choose("what to make", filterable: false, {
                    [Picker.Item(id: "bot", label: "Bot"), Picker.Item(id: "group", label: "Group")]
                }) else { return }
                kind = item.id
            }
            switch kind {
            case "bot": await newBot()
            case "group": await newGroup()
            default: tell("/new makes a bot or a group.")
            }
        }
    }

    // MARK: Bots

    private func newBot() async {
        let title = "New bot"
        guard let chats = await chooseHub(for: title) else { return }
        var draft = LinkBotDraft(name: "", provider: "", avatarSymbolName: "sparkles", avatarColorIndex: Int.random(in: 0..<Self.colourNames.count))
        guard let name = await askRequired(title, "Name"),
              let about = await ask(title, "Description", placeholder: "Description, optional"),
              let backstory = await ask(title, "Backstory", placeholder: "Backstory: who this bot is, its role, tone or priorities; optional")
        else { return }
        draft.name = name
        draft.publicDescription = about.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.backstory = backstory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await chooseHarness(&draft, in: chats, keeping: nil), await chooseModel(&draft, in: chats, required: false) else { return }
        do {
            let bot = try await chats.create(draft)
            if let made = hubs.row(TerminalHubs.Row(chats: chats, thread: .bot(bot)).id) { open(made) }
            tell("\(name) is made.")
        } catch {
            tell(error.localizedDescription)
        }
    }

    /// Chooses the harness the bot runs on. False when the form is cancelled or the plan lends none.
    private func chooseHarness(_ draft: inout LinkBotDraft, in chats: HubChats, keeping kept: LinkBotDraft?) async -> Bool {
        let harnesses = chats.harnesses(keeping: kept)
        guard !harnesses.isEmpty else {
            tell("Your plan lends no harnesses.")
            return false
        }
        let current = draft
        guard let item = await choose("harnesses", {
            harnesses.enumerated().map { index, lent in
                Picker.Item(id: "\(index)", label: lent.profileName.map { "\(lent.providerName) · \($0)" } ?? lent.providerName,
                            current: lent.provider == current.provider && lent.profile == current.profile)
            }
        }), let index = Int(item.id) else { return false }
        let chosen = harnesses[index]
        guard chosen.provider != draft.provider || chosen.profile != draft.profile else { return true }
        draft.provider = chosen.provider
        draft.profile = chosen.profile
        draft.reasoningEffort = nil
        draft.setModel(chosen.initialModel, on: chosen)
        draft.model = chosen.initialModel
        return true
    }

    private func harness(of draft: LinkBotDraft, in chats: HubChats) -> LinkHarness? {
        chats.harnesses(keeping: draft).first { $0.provider == draft.provider && $0.profile == draft.profile }
    }

    /// The models the harness offers, plus the bot's current one if the plan no longer lends it.
    func models(for draft: LinkBotDraft, in chats: HubChats) -> [LinkModel] {
        var models = harness(of: draft, in: chats)?.models ?? []
        if let model = draft.model, !models.contains(where: { $0.id == model }) { models.insert(LinkModel(id: model, name: model), at: 0) }
        return models
    }

    func efforts(for draft: LinkBotDraft, in chats: HubChats) -> [LinkEffort] {
        models(for: draft, in: chats).first { $0.id == draft.model }?.efforts ?? []
    }

    /// Chooses the model, when the harness offers a choice. False when the form is cancelled.
    private func chooseModel(_ draft: inout LinkBotDraft, in chats: HubChats, required: Bool) async -> Bool {
        guard let harness = harness(of: draft, in: chats) else { return true }
        let models = models(for: draft, in: chats)
        guard !models.isEmpty, required || harness.restrictsModels || draft.model == nil else { return true }
        let current = draft.model
        let offersDefault = !harness.restrictsModels
        guard let item = await choose("models", {
            (offersDefault ? [Picker.Item(id: "", label: "Default", detail: "As the harness chooses", current: current == nil)] : [])
                + models.map { Picker.Item(id: $0.id, label: $0.name, current: $0.id == current) }
        }) else { return false }
        let chosen = item.id.isEmpty ? nil : item.id
        if chosen != draft.model {
            draft.setModel(chosen, on: harness)
            draft.model = chosen
        }
        return true
    }

    /// Saves a change to the bot on screen, made to its draft as the Hub has it now.
    private func changeBot(_ change: @escaping @MainActor (inout LinkBotDraft, HubChats) async -> Bool) {
        guard let (row, bot) = ownedBot else { return }
        Task {
            var draft = bot.draft
            guard await change(&draft, row.chats), draft != bot.draft else { return }
            let latest = row.chats.bots.first { $0.id == bot.id } ?? bot
            do {
                try await row.chats.update(latest, to: draft)
                tell("Saved.")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    func edit() {
        guard let row else { return }
        switch row.thread {
        case .bot(let bot):
            let title = "Edit \(bot.draft.name)"
            changeBot { draft, _ in
                guard let name = await self.askRequired(title, "Name", value: draft.name),
                      let about = await self.ask(title, "Description", value: draft.publicDescription, placeholder: "Description, optional"),
                      let backstory = await self.ask(title, "Backstory", value: draft.backstory,
                                                     placeholder: "Backstory: who this bot is, its role, tone or priorities; optional")
                else { return false }
                draft.name = name
                draft.publicDescription = about.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.backstory = backstory.trimmingCharacters(in: .whitespacesAndNewlines)
                return true
            }
        case .group(let group):
            let title = "Edit \(group.draft.name)"
            changeGroup(group, in: row.chats) { draft, chats in
                guard let name = await self.askRequired(title, "Name", value: draft.name),
                      let about = await self.ask(title, "Description", value: draft.publicDescription, placeholder: "Description, optional"),
                      let members = await self.chooseMembers(of: draft, in: chats)
                else { return false }
                draft.name = name
                draft.publicDescription = about.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.botIDs = members
                return true
            }
        }
    }

    func changeHarness() {
        changeBot { draft, chats in
            let kept = draft
            guard await self.chooseHarness(&draft, in: chats, keeping: kept) else { return false }
            // A harness that only lends some models needs one of them chosen.
            if let harness = self.harness(of: draft, in: chats), harness.restrictsModels, draft.provider != kept.provider || draft.profile != kept.profile {
                return await self.chooseModel(&draft, in: chats, required: true)
            }
            return true
        }
    }

    func changeModel() {
        changeBot { draft, chats in await self.chooseModel(&draft, in: chats, required: true) }
    }

    func changeEffort() {
        changeBot { draft, chats in
            let efforts = self.efforts(for: draft, in: chats), current = draft.reasoningEffort
            guard let item = await self.choose("efforts", {
                [Picker.Item(id: "", label: "Default", current: current == nil)]
                    + efforts.map { Picker.Item(id: $0.id, label: $0.name, current: $0.id == current) }
            }) else { return false }
            draft.reasoningEffort = item.id.isEmpty ? nil : item.id
            return true
        }
    }

    func changeColour() {
        changeBot { draft, _ in
            let current = Self.colourIndex(draft.avatarColorIndex)
            guard let item = await self.choose("colours", {
                Self.colourNames.enumerated().map { Picker.Item(id: "\($0.offset)", label: $0.element, current: $0.offset == current) }
            }), let index = Int(item.id) else { return false }
            draft.avatarColorIndex = index
            return true
        }
    }

    func changeSymbol(_ typed: String) {
        changeBot { draft, _ in
            var symbol = typed.trimmingCharacters(in: .whitespaces)
            if symbol.isEmpty {
                guard let answer = await self.ask("Symbol for \(draft.name)", "Symbol", value: draft.avatarSymbolName ?? "",
                                                  placeholder: "Symbol, such as sparkles or brain.head.profile") else { return false }
                symbol = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            draft.avatarSymbolName = symbol.isEmpty ? nil : symbol
            // A bot's own picture shows instead of its symbol, until it is taken away.
            if draft.hasPicture {
                guard let item = await self.choose("\(draft.name) has a picture", filterable: false, {
                    [Picker.Item(id: "keep", label: "Keep Picture"), Picker.Item(id: "symbol", label: "Use Symbol Instead of Picture")]
                }) else { return false }
                if item.id == "symbol" { draft.removePicture() }
            }
            return true
        }
    }

    // MARK: Groups

    private func newGroup() async {
        let title = "New group"
        guard let chats = await chooseHub(for: title) else { return }
        var draft = LinkGroupDraft(name: "", botIDs: [])
        guard let name = await askRequired(title, "Name"),
              let about = await ask(title, "Description", placeholder: "Description, optional"),
              let members = await chooseMembers(of: draft, in: chats)
        else { return }
        draft.name = name
        draft.publicDescription = about.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.botIDs = members
        do {
            let group = try await chats.createGroup(draft)
            if let made = hubs.row(TerminalHubs.Row(chats: chats, thread: .group(group)).id) { open(made) }
            tell("\(name) is made.")
        } catch {
            tell(error.localizedDescription)
        }
    }

    /// Chooses a group's bots, at least one. Bots that cannot be chosen any more, such as archived ones, stay.
    private func chooseMembers(of draft: LinkGroupDraft, in chats: HubChats) async -> [UUID]? {
        let candidates = chats.bots.filter { $0.archivedAt == nil && $0.owner == nil }
        guard !candidates.isEmpty else {
            tell("Make a bot first: /new bot")
            return nil
        }
        var checked = Set(draft.botIDs.map(\.uuidString))
        while true {
            guard let chosen = await chooseSeveral("bots", checked: checked, {
                candidates.map { Picker.Item(id: $0.id.uuidString, label: $0.draft.name, detail: $0.draft.publicDescription) }
            }) else { return nil }
            let kept = draft.botIDs.filter { id in !candidates.contains { $0.id == id } }
            let members = kept + candidates.map(\.id).filter { chosen.contains($0.uuidString) }
            if !members.isEmpty { return members }
            tell("Choose at least one bot.")
            checked = chosen
        }
    }

    private func changeGroup(_ group: LinkGroup, in chats: HubChats, _ change: @escaping @MainActor (inout LinkGroupDraft, HubChats) async -> Bool) {
        Task {
            var draft = group.draft
            guard await change(&draft, chats), draft != group.draft else { return }
            let latest = chats.groups.first { $0.id == group.id } ?? group
            do {
                try await chats.updateGroup(latest, to: draft)
                tell("Saved.")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    func changeMembers() {
        guard let row, let group = row.thread.group else { return }
        changeGroup(group, in: row.chats) { draft, chats in
            guard let members = await self.chooseMembers(of: draft, in: chats) else { return false }
            draft.botIDs = members
            return true
        }
    }

    // MARK: A bot's tools, sharing and run

    func chooseTools(_ kind: HubChats.Tool) {
        guard let (row, bot) = ownedBot else { return }
        let chats = row.chats
        let name = switch kind {
        case .connection: "tools"
        case .computer: "computers"
        case .browser: "browsers"
        }
        let tools = chats.tools(kind, for: bot)
        guard !tools.isEmpty else { return tell("You have no \(name) on \(chats.hubName). Add them in Noodle on your Mac or phone.") }
        Task {
            guard let chosen = await chooseSeveral("\(name) for \(bot.draft.name)", checked: Set(tools.filter(\.assigned).map(\.id.uuidString)), {
                chats.tools(kind, for: bot).map { Picker.Item(id: $0.id.uuidString, label: $0.name, detail: $0.detail ?? "") }
            }) else { return }
            do {
                for tool in chats.tools(kind, for: bot) where tool.assigned != chosen.contains(tool.id.uuidString) {
                    try await chats.setAssigned(!tool.assigned, kind, tool.id, for: bot)
                }
                tell("Saved.")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    func share() {
        guard let (row, bot) = ownedBot else { return }
        let chats = row.chats
        Task {
            let people: [LinkPerson]
            do { people = try await chats.people() } catch { return tell(error.localizedDescription) }
            guard !people.isEmpty else { return tell("Nobody else is on \(chats.hubName).") }
            let shared = Set((chats.bots.first { $0.id == bot.id } ?? bot).sharedWith)
            guard let chosen = await chooseSeveral("people to share \(bot.draft.name) with", checked: Set(shared.map(\.uuidString)), {
                people.map { Picker.Item(id: $0.id.uuidString, label: $0.name) }
            }) else { return }
            do {
                for person in people where shared.contains(person.id) != chosen.contains(person.id.uuidString) {
                    let latest = chats.bots.first { $0.id == bot.id } ?? bot
                    try await chats.setShared(!shared.contains(person.id), latest, with: person.id)
                }
                tell("Saved. They can talk with \(bot.draft.name); only you can change it.")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    func newSession() {
        guard let (row, bot) = ownedBot else { return }
        let name = bot.draft.name
        Task {
            guard await confirm("Start a new session for \(name)?",
                                "\(name) will start with a fresh context. Its workspace, memory and messages are kept.", button: "New Session") else { return }
            do {
                try await row.chats.startNewSession(bot)
                tell("\(name) is starting a new session.")
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    func organize() {
        guard let (row, bot) = ownedBot else { return }
        perform {
            try await row.chats.organize(bot)
            self.tell("\(bot.draft.name) is organizing.")
        }
    }

    /// Starts a stuck bot again; the Hub may first ask what to do.
    func kick() {
        guard let (row, bot) = ownedBot else { return }
        let chats = row.chats, name = bot.draft.name
        Task {
            do {
                guard let question = try await chats.kick(bot) else { return tell("\(name) is starting again.") }
                let result = await pick(Picker(title: question.title, verb: "chooses", message: [question.message], items: {
                    [Picker.Item(id: "kick", label: question.confirmTitle)]
                        + (question.offersNewSession ? [Picker.Item(id: "session", label: "New Session")] : [])
                        + [Picker.Item(id: "cancel", label: "Cancel")]
                }, filterable: false, selection: question.offersNewSession ? 2 : 1))
                guard case .chose(let item) = result else { return }
                switch item.id {
                case "kick":
                    try await chats.confirmKick(question, for: bot)
                    tell("\(name) is starting again.")
                case "session":
                    try await chats.startNewSession(bot)
                    tell("\(name) is starting a new session.")
                default:
                    break
                }
            } catch {
                tell(error.localizedDescription)
            }
        }
    }

    func delete() {
        guard let row else { return }
        let chats = row.chats, name = row.thread.name
        Task {
            switch row.thread {
            case .bot(let bot):
                guard bot.owner == nil, await confirm("Delete \(name)?", "The bot and its conversation are deleted from the Hub for all your devices.",
                                                      button: "Delete") else { return }
                do { try await chats.delete(bot) } catch { return tell(error.localizedDescription) }
            case .group(let group):
                guard await confirm("Delete \(name)?",
                                    "The group and its conversation are deleted from the Hub for all your devices. Its bots are kept.",
                                    button: "Delete") else { return }
                do { try await chats.deleteGroup(group) } catch { return tell(error.localizedDescription) }
            }
            tell("\(name) is deleted.")
        }
    }

    // MARK: Hubs

    private func status(of chats: HubChats) -> String {
        let status = chats.pairing.status
        return ([chats.isConnected ? "Connected" : "Not connected", status?.userName ?? chats.pairing.hub?.userName,
                 status.map { "\($0.planName) plan" }, status?.isAdmin == true ? "Admin" : nil,
                 chats.isConnected ? nil : chats.pairing.error ?? chats.error] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }

    func showHubs() {
        Task {
            guard let item = await choose("Hubs", { [self] in
                hubs.chats.map { Picker.Item(id: "\($0.id.hashValue)", label: $0.hubName, detail: status(of: $0)) }
                    + [Picker.Item(id: "join", label: "Join Another Hub…", detail: "With an invitation link or code")]
            }) else { return }
            if item.id == "join" { return setInput("/join ") }
            guard let chats = hubs.chats.first(where: { "\($0.id.hashValue)" == item.id }) else { return }
            await manage(chats)
        }
    }

    /// What can be done with one Hub, until the person is done.
    private func manage(_ chats: HubChats) async {
        while hubs.chats.contains(where: { $0 === chats }) {
            guard let item = await choose(chats.hubName, verb: "chooses", message: [status(of: chats)], filterable: false, { [self] in
                let status = chats.pairing.status
                var items: [Picker.Item] = []
                if hubs.chats.count > 1 {
                    items.append(hubs.space == .hub(chats.id)
                        ? Picker.Item(id: "all", label: "Show All Hubs", detail: "Every Hub's bots and groups")
                        : Picker.Item(id: "space", label: "Show Only This Hub", detail: "Only this Hub's bots and groups"))
                }
                if status?.canPairDevices == true { items.append(Picker.Item(id: "pair", label: "Pair Another Device")) }
                if status?.isAdmin == true { items.append(Picker.Item(id: "users", label: "Users")) }
                if chats.mutesGroups {
                    items.append(Picker.Item(id: "notify", label: "Groups Notify",
                                             detail: Self.levelName(status?.groupNotifications ?? .all)))
                }
                items.append(Picker.Item(id: "leave", label: "Leave", detail: "Stop showing its bots and groups here"))
                return items
            }) else { return }
            switch item.id {
            case "all": hubs.space = .all; return
            case "space": hubs.space = .hub(chats.id); return
            case "pair": return await pair(with: chats)
            case "users": return await manageUsers(of: chats)
            case "notify":
                let levels: [LinkNotifications] = [.all] + (chats.notifiesMentions ? [.mentions] : [])
                let current = chats.pairing.status?.groupNotifications ?? .all
                guard let level = await choose("how groups notify you", {
                    levels.enumerated().map { Picker.Item(id: "\($0.offset)", label: Self.levelName($0.element), current: $0.element == current) }
                }), let index = Int(level.id) else { continue }
                do { try await chats.setGroupNotifications(levels[index]) } catch { tell(error.localizedDescription) }
            case "leave":
                guard await confirm("Leave \(chats.hubName)?",
                                    "\(Desktop.Computer) stops showing its bots and groups. They stay on the Hub, and you can join again with a new invitation.",
                                    button: "Leave") else { continue }
                let name = chats.hubName
                hubs.leave(chats)
                tell("Left \(name).")
                return
            default: return
            }
        }
    }

    private static func levelName(_ level: LinkNotifications) -> String { level == .mentions ? "Mentions only" : "All messages" }

    /// Shows a one-time invitation link, with a way to copy it.
    private func showInvitation(_ invitation: LinkInvitation, title: String, words: String) async {
        let link = invitation.url().absoluteString
        guard let item = await choose(title, verb: "chooses", message: [words, link], filterable: false, {
            [Picker.Item(id: "copy", label: "Copy Link"), Picker.Item(id: "close", label: "Close")]
        }) else { return }
        if item.id == "copy" {
            Desktop.copy(link, through: console)
            tell("Copied.")
        }
    }

    func pairDevice() {
        Task {
            let able = hubs.chats.filter { $0.pairing.status?.canPairDevices == true }
            var chats = able.first
            if able.count > 1 {
                guard let item = await choose("Hubs", {
                    able.enumerated().map { Picker.Item(id: "\($0.offset)", label: $0.element.hubName) }
                }), let index = Int(item.id) else { return }
                chats = able[index]
            }
            if let chats { await pair(with: chats) }
        }
    }

    private func pair(with chats: HubChats) async {
        tell("Asking the Hub…")
        do {
            let invitation = try await chats.pairing.invite()
            clearNotice()
            let until = invitation.expires.formatted(date: .omitted, time: .shortened)
            await showInvitation(invitation, title: "Pair another device with \(chats.hubName)",
                                 words: "On the other device, join a Hub and paste this link. It works once, until \(until).")
        } catch {
            tell(error.localizedDescription)
        }
    }

    private func clearNotice() { notice = nil }

    // MARK: Users

    func manageUsers() {
        Task {
            let admin = hubs.chats.filter { $0.pairing.status?.isAdmin == true }
            var chats = admin.first
            if admin.count > 1 {
                guard let item = await choose("Hubs", {
                    admin.enumerated().map { Picker.Item(id: "\($0.offset)", label: $0.element.hubName) }
                }), let index = Int(item.id) else { return }
                chats = admin[index]
            }
            if let chats { await manageUsers(of: chats) }
        }
    }

    private func users(of chats: HubChats) -> HubUsers {
        if let kept = users[chats.id] { return kept }
        let made = HubUsers(pairing: chats.pairing)
        users[chats.id] = made
        return made
    }

    /// Everyone on a Hub, for its admins: choose one to change, or add someone.
    private func manageUsers(of chats: HubChats) async {
        let people = users(of: chats)
        tell("Asking the Hub…")
        await people.load()
        clearNotice()
        if let error = people.error, people.users.isEmpty { return tell(error) }
        while true {
            guard let item = await choose("users of \(chats.hubName)", {
                [Picker.Item(id: "add", label: "Add User…")] + people.users.map { user in
                    Picker.Item(id: user.id.uuidString, label: user.name,
                                detail: ([people.planName(of: user)] + user.tags.map(\.title)).compactMap { $0 }.joined(separator: " · "))
                }
            }) else { return }
            if item.id == "add" {
                guard let name = await askRequired("New user on \(chats.hubName)", "Name") else { continue }
                if let user = await people.add(named: name) { await manage(user.id, in: people) } else if let error = people.error { tell(error) }
                continue
            }
            if let id = UUID(uuidString: item.id) { await manage(id, in: people) }
        }
    }

    private func onOff(_ on: Bool) -> String { on ? "On" : "Off" }

    /// One user: their name, plan, whether they can pair devices or are suspended, their devices, removing them.
    /// Admins are changed on the Hub itself.
    private func manage(_ id: UUID, in people: HubUsers) async {
        while let user = people.users.first(where: { $0.id == id }) {
            if let error = people.error { tell(error) }
            let message = user.isAdmin ? ["An admin. Only the Hub changes admins."] : []
            guard let item = await choose(user.name, verb: "chooses", message: message, filterable: false, {
                guard let user = people.users.first(where: { $0.id == id }) else { return [] }
                var items: [Picker.Item] = []
                if !user.isAdmin {
                    items += [
                        Picker.Item(id: "rename", label: "Rename…", detail: user.name),
                        Picker.Item(id: "plan", label: "Plan", detail: people.planName(of: user) ?? ""),
                        Picker.Item(id: "pair", label: "Can Pair Devices", detail: self.onOff(user.canPairDevices)),
                        Picker.Item(id: "suspend", label: "Suspended", detail: self.onOff(user.isSuspended)
                            + " · Suspended stops their Hub bots and blocks their devices"),
                        Picker.Item(id: "invite", label: "Invite a Device"),
                    ]
                }
                items.append(Picker.Item(id: "devices", label: "Devices", detail: user.devices.isEmpty ? "None" : "\(user.devices.count)"))
                if !user.isAdmin { items.append(Picker.Item(id: "remove", label: "Remove \(user.name)")) }
                return items
            }) else { return }
            switch item.id {
            case "rename":
                guard let name = await askRequired("Rename \(user.name)", "Name", value: user.name), name != user.name else { continue }
                await people.rename(user, to: name)
            case "plan":
                guard let plan = await choose("plans", {
                    people.plans.map { Picker.Item(id: $0.id.uuidString, label: $0.name, current: $0.id == user.plan) }
                }), let planID = UUID(uuidString: plan.id), planID != user.plan else { continue }
                await people.move(user, to: planID)
            case "pair":
                await people.setCanPairDevices(!user.canPairDevices, for: user)
            case "suspend":
                await people.setSuspended(!user.isSuspended, for: user)
            case "invite":
                if let invitation = await people.invite(user) {
                    await showInvitation(invitation, title: "Invite a device for \(user.name)",
                                         words: "On \(user.name)'s device, join a Hub and paste this link. It works once.")
                }
            case "devices":
                await manageDevices(of: id, in: people)
            case "remove":
                guard await confirm("Remove \(user.name)?", "Their bots, groups and devices are removed from the Hub.", button: "Remove") else { continue }
                await people.remove(user)
                if let error = people.error { tell(error) } else { tell("\(user.name) is removed.") }
                return
            default:
                return
            }
        }
    }

    private func manageDevices(of id: UUID, in people: HubUsers) async {
        while let user = people.users.first(where: { $0.id == id }) {
            guard !user.devices.isEmpty else { return tell("\(user.name) has no devices.") }
            guard let item = await choose("devices of \(user.name)", verb: user.isAdmin ? "closes" : "removes", {
                (people.users.first { $0.id == id }?.devices ?? []).map { device in
                    Picker.Item(id: device.id.uuidString, label: device.name,
                                detail: device.isConnected ? "Connected" : device.lastSeen.map { "Seen \($0.formatted(.relative(presentation: .named)))" } ?? "")
                }
            }) else { return }
            guard !user.isAdmin else { return }
            guard let device = user.devices.first(where: { $0.id.uuidString == item.id }),
                  await confirm("Remove \(device.name)?", "It can no longer reach the Hub until it joins again.", button: "Remove") else { continue }
            await people.remove(device)
            if let error = people.error { tell(error) } else { tell("\(device.name) is removed.") }
        }
    }
}
