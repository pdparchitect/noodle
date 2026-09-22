#if NOODLE_DEV_HOOKS
import AppKit
import Darwin
import NoodleCore
import NoodleLaunchChecks
import SwiftUI
import UniformTypeIdentifiers

/// A screenshot scenario: `Scenarios/NAME/scenario.json`, replayed through the real repository with
/// scripted bots in place of harnesses. Development builds only; the format is in Scenarios/README.md.
struct Scenario: Codable {
    var version: Int
    var title: String
    var clock: String?
    var appearance: String?
    var settings: [String: Setting]?
    var harnesses: [String: Harness]
    var agents: [Agent]
    var conversations: [Conversation]?
    var present: Presentation?
    var timeline: [Step]?
    var film: Film?
    /// Where `scenario.json` was read; asset paths are relative to it.
    var folder = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case version, title, clock, appearance, settings, harnesses, agents, conversations, present, timeline, film
    }

    enum Setting: Codable, Equatable {
        case bool(Bool), number(Double), text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .text(try container.decode(String.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            }
        }

        var propertyListValue: Any {
            switch self {
            case .bool(let value): return value
            case .number(let value): return value == value.rounded() ? Int(value) : value
            case .text(let value): return value
            }
        }
    }

    struct Harness: Codable {
        /// `"builtin"` for Claude Code's fixed catalogue, otherwise the models the harness would report.
        var models: Models

        enum Models: Codable {
            case builtin, list([Model])

            init(from decoder: Decoder) throws {
                if let models = try? [Model](from: decoder) { self = .list(models); return }
                guard try String(from: decoder) == "builtin" else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "models is \"builtin\" or a list"))
                }
                self = .builtin
            }

            func encode(to encoder: Encoder) throws {
                switch self {
                case .builtin: try "builtin".encode(to: encoder)
                case .list(let models): try models.encode(to: encoder)
                }
            }
        }

        struct Model: Codable {
            var id: String
            var name: String
            var description: String?
            var efforts: [String]?
            var defaultEffort: String?
            var `default`: Bool?
        }
    }

    struct Agent: Codable {
        var key: String
        var name: String
        var harness: String
        var model: String?
        var effort: String?
        var description: String?
        var backstory: String?
        var avatar: Avatar?
        var status: Status?
        var unrestricted: Bool?
        var autoReplies: [String]?

        struct Avatar: Codable {
            var image: String?
            var symbol: String?
            var colour: Int?
        }
    }

    struct Status: Codable {
        var phase: AgentRuntimePhase
        var detail: String?
        var failure: Failure?

        enum Failure: String, Codable {
            case missingSession, usageLimit, authenticationRequired, recoveryFailed
        }
    }

    struct Conversation: Codable {
        var key: String
        var direct: String?
        var group: Group?
        var background: Background?
        var unread: Bool?
        var messages: [Message]?

        struct Group: Codable {
            var name: String
            var description: String?
            var members: [String]
        }

        struct Background: Codable {
            var preset: ConversationBackgroundPreset?
            var image: String?
        }
    }

    struct Message: Codable {
        var key: String?
        var at: String
        var from: String
        var text: String
        var delivery: MessageDelivery?
        var attachments: [Attachment]?
        var reactions: [Reaction]?
    }

    struct Attachment: Codable {
        var file: String?
        var link: String?
    }

    struct Reaction: Codable {
        var from: String
        var emoji: String
    }

    struct Presentation: Codable {
        var window: Window?
        var sidebar: Sidebar?
        var select: String?
        var search: String?
        var draft: String?
        var draftAttachments: [String]?
        var scroll: [String: String]?
        var windows: [ExtraWindow]?
        var sheet: Sheet?

        enum Sidebar: String, Codable { case visible, hidden }

        struct Window: Codable {
            var size: [Double]
            var origin: [Double]?
        }

        struct ExtraWindow: Codable {
            var conversation: String?
            var frame: [Double]?
            var floating: Bool?
            var activity: String?
            var settings: String?
        }

        /// Every sheet of the main window; the ones left out are closed.
        struct Sheet: Codable {
            var newBot: Bool?
            var newGroup: Bool?
            var firstBotSetup: Bool?
            var editBot: String?
            var groupInfo: String?
            var background: String?
        }
    }

    /// Titles around the scenario, so a recording opens and closes the same way every time.
    struct Film: Codable {
        /// The solid colour behind the app and under the titles: "black" or "white".
        var background: String?
        var intro: Intro?
        var outro: Outro?

        struct Intro: Codable {
            /// A picture to bring up under the title, shown in a circle. Any asset in the
            /// scenario folder, so it can be a bot's own avatar or anything else.
            var icon: String?
            /// The small line above the title, for what this is a scenario of.
            var kicker: String?
            /// Defaults to the scenario's own title.
            var title: String?
            var subtitle: String?
            /// Seconds to stay on the finished card. Default 1.4.
            var hold: Double?
        }

        struct Outro: Codable {
            var tagline: String?
            /// Seconds to stay on the finished wordmark. Default 1.6.
            var hold: Double?
        }

        enum Stage { case intro, outro }
    }

    struct Step: Codable {
        var wait: Double?
        var agent: String?
        var `in`: String?
        var status: Status?
        var reply: Content?
        var say: Content?
        var type: Typing?
        var react: React?
        var stream: Stream?
        var toolCall: ToolCall?
        var error: String?
        var waitFor: Wait?
        var present: Presentation?
        var capture: String?

        enum Wait: String, Codable { case userMessage, key }

        struct Content: Codable {
            var key: String?
            var text: String
            var attachments: [Attachment]?
        }

        /// A message typed into the composer a character at a time, then sent.
        struct Typing: Codable {
            var key: String?
            var text: String
            var attachments: [Attachment]?
            var interval: Double?
        }

        struct React: Codable {
            var message: String
            var emoji: String
            var remove: Bool?
        }

        struct Stream: Codable {
            var text: String
            var chunk: Int?
            var interval: Double?
        }

        struct ToolCall: Codable {
            var title: String?
            var input: String
            var output: String?
            var exit: Int?
            var duration: Double?
        }

        var actions: Int {
            [status != nil, reply != nil, say != nil, type != nil, react != nil, stream != nil, toolCall != nil, error != nil,
             waitFor != nil, present != nil, capture != nil].filter { $0 }.count
        }
    }
}

struct ScenarioError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

// MARK: - Load and validate

extension Scenario {
    static let settingsTabs: [String: NoodleSettingsTab] = [
        "general": .general, "chat": .chat, "harnesses": .harnesses, "mcps": .mcps, "heartbeats": .heartbeats,
        "sandbox": .sandbox, "keybindings": .keybindings, "permissions": .permissions, "companions": .companions, "updates": .updates
    ]

    /// Preferences a scenario may set. Message delivery is absent: the loader always queues, so the
    /// on-device classifier never runs.
    @MainActor static var preferenceKeys: Set<String> {
        [ChatAttachmentLayout.defaultsKey, BotNameStyle.defaultsKey, FirstBotSetup.dismissedKey,
         ComposerNameCompletion.descriptionsDefaultsKey, FloatingConversations.keepsOneDefaultsKey, LinkPreviewSettings.timeoutKey]
    }

    /// Strict: a key the model does not know is an error, so a typo cannot silently change a screenshot.
    @MainActor static func load(from folder: URL) throws -> Scenario {
        let file = folder.appendingPathComponent("scenario.json")
        guard let data = try? Data(contentsOf: file) else { throw ScenarioError("There is no scenario at \(file.path).") }
        var scenario: Scenario
        do { scenario = try JSONDecoder().decode(Scenario.self, from: data) }
        catch let error as DecodingError { throw ScenarioError("\(file.lastPathComponent): \(Self.describe(error))") }
        let unknown = ScenarioSupport.unknownKeys(in: try JSONSerialization.jsonObject(with: data),
            comparedTo: try JSONSerialization.jsonObject(with: JSONEncoder().encode(scenario)))
        guard unknown.isEmpty else { throw ScenarioError("Unknown keys in \(file.lastPathComponent): \(unknown.joined(separator: ", "))") }
        scenario.folder = folder.standardizedFileURL
        try scenario.validate()
        return scenario
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "\(path(context)) is missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    func asset(_ path: String) throws -> URL {
        let url = folder.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: url.path) else {
            throw ScenarioError("Missing asset: \(path)")
        }
        return url
    }

    func models(for provider: HarnessProvider) -> [HarnessModel] {
        guard let harness = harnesses[provider.rawValue] else { return [] }
        guard case .list(let models) = harness.models else { return ClaudeCodeCapabilities.models }
        let descriptions = Dictionary(uniqueKeysWithValues: ClaudeCodeCapabilities.efforts.map { ($0.id, $0.description) })
        return models.map { model in
            let efforts = model.efforts ?? []
            return HarnessModel(id: model.id, displayName: model.name, description: model.description ?? "",
                supportedEfforts: efforts.map { HarnessEffort(id: $0, description: descriptions[$0] ?? "") },
                defaultEffort: model.defaultEffort ?? efforts.first ?? "", isDefault: model.default ?? false)
        }
    }

    @MainActor func validate() throws {
        func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition { throw ScenarioError(message()) }
        }
        try require(version == 1, "Scenario version \(version) is not supported.")
        try require(appearance == nil || appearance == "dark", "Noodle is dark only: appearance must be \"dark\" or left out.")
        _ = try ScenarioSupport.start(clock, now: Date())
        if let film {
            try require(["black", "white"].contains(film.background ?? "black"), "film.background is \"black\" or \"white\".")
            for (label, text) in [("intro.kicker", film.intro?.kicker), ("intro.title", film.intro?.title),
                                  ("intro.subtitle", film.intro?.subtitle), ("outro.tagline", film.outro?.tagline)] {
                try require(text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true, "film.\(label) has no text.")
            }
            try require((film.intro?.hold ?? 0) >= 0 && (film.outro?.hold ?? 0) >= 0, "A film holds for a negative time.")
            if let icon = film.intro?.icon { _ = try asset(icon) }
        }
        for key in (settings ?? [:]).keys {
            try require(Self.preferenceKeys.contains(key), "\"\(key)\" is not a preference a scenario can set.")
        }
        for (identifier, harness) in harnesses {
            guard let provider = HarnessProvider(rawValue: identifier), provider != .apple else {
                throw ScenarioError("\"\(identifier)\" is not a harness a scenario can script.")
            }
            if case .builtin = harness.models { try require(provider == .claudeCode, "Only claude-code has builtin models.") }
            for model in models(for: provider) where !model.supportedEfforts.isEmpty {
                try require(model.supportedEfforts.contains { $0.id == model.defaultEffort }, "\(model.id) has no effort \"\(model.defaultEffort)\".")
            }
        }

        try require(Set(agents.map(\.key)).count == agents.count, "Bot keys must be unique.")
        for agent in agents {
            try require(!agent.key.isEmpty && agent.key != "user", "\"\(agent.key)\" cannot be a bot key.")
            guard let provider = HarnessProvider(rawValue: agent.harness), harnesses[agent.harness] != nil else {
                throw ScenarioError("\(agent.key) uses \"\(agent.harness)\", which harnesses does not list.")
            }
            if let identifier = agent.model {
                guard let model = models(for: provider).first(where: { $0.id == identifier }) else {
                    throw ScenarioError("\(agent.key) uses the model \"\(identifier)\", which \(agent.harness) does not list.")
                }
                if let effort = agent.effort {
                    try require(model.supportedEfforts.contains { $0.id == effort }, "\(identifier) has no effort \"\(effort)\".")
                }
            }
            if let image = agent.avatar?.image { _ = try asset(image) }
            try Self.check(agent.status, of: agent.key)
        }

        var messageKeys = Set<String>()
        func register(_ key: String?) throws {
            guard let key else { return }
            try require(messageKeys.insert(key).inserted, "Message key \"\(key)\" is used twice.")
        }
        func check(_ attachments: [Attachment]?) throws {
            for attachment in attachments ?? [] {
                try require((attachment.file == nil) != (attachment.link == nil), "An attachment is either a file or a link.")
                if let file = attachment.file { _ = try asset(file) }
                if let link = attachment.link {
                    try require(URL(string: link).flatMap { MessageLink.publicWebURL(from: $0, preservingFragment: true) } != nil,
                                "\"\(link)\" is not a public web link.")
                }
            }
        }
        let conversations = conversations ?? []
        try require(Set(conversations.map(\.key)).count == conversations.count, "Conversation keys must be unique.")
        try require(Set(conversations.compactMap(\.direct)).count == conversations.compactMap(\.direct).count, "A bot has one direct conversation.")
        var members: [String: Set<String>] = [:]
        for conversation in conversations {
            try require((conversation.direct == nil) != (conversation.group == nil), "\(conversation.key) is either direct or a group.")
            let participants = Set(conversation.direct.map { [$0] } ?? conversation.group?.members ?? [])
            try require(!participants.isEmpty && participants.isSubset(of: agents.map(\.key)), "\(conversation.key) names a bot that does not exist.")
            members[conversation.key] = participants
            if let background = conversation.background {
                try require((background.preset == nil) != (background.image == nil), "A background is either a preset or an image.")
                if let image = background.image { _ = try asset(image) }
            }
            var previous = Date.distantPast
            for message in conversation.messages ?? [] {
                try register(message.key)
                try require(message.from == "user" || participants.contains(message.from), "\(message.from) is not in \(conversation.key).")
                try require(!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "A message in \(conversation.key) has no text.")
                // A bot fetches a queued message as it starts, which would deliver it; `say` in the timeline sends one live.
                let allowed: [MessageDelivery] = message.from == "user" ? [.saved, .delivered, .failed] : [.delivered]
                try require(message.delivery.map(allowed.contains) ?? true, "\(conversation.key): a seeded message from \(message.from) cannot be \(message.delivery?.rawValue ?? "").")
                let date = try ScenarioSupport.date(message.at, clock: Date())
                try require(date >= previous, "Messages in \(conversation.key) must be in time order (\(message.at)).")
                previous = date
                try check(message.attachments)
                for reaction in message.reactions ?? [] {
                    try require(reaction.from == "user" || participants.contains(reaction.from), "\(reaction.from) is not in \(conversation.key).")
                    try require(MessageReaction.isValidEmoji(reaction.emoji), "\"\(reaction.emoji)\" is not a single emoji.")
                }
            }
        }

        func check(_ present: Presentation?, initial: Bool) throws {
            guard let present else { return }
            if let window = present.window {
                try require(window.size.count == 2 && (window.origin?.count ?? 2) == 2, "A window has a size of [width, height] and an origin of [x, y].")
            }
            for key in [present.select, present.sheet?.groupInfo, present.sheet?.background].compactMap({ $0 }) + (present.scroll ?? [:]).keys {
                try require(members[key] != nil, "present names the conversation \"\(key)\", which does not exist.")
            }
            if let key = present.sheet?.groupInfo { try require(conversations.first { $0.key == key }?.group != nil, "\(key) is not a group.") }
            try require(present.draft == nil && present.draftAttachments == nil || present.select != nil, "A draft needs present.select.")
            for path in present.draftAttachments ?? [] { _ = try asset(path) }
            for (key, position) in present.scroll ?? [:] {
                try require(position == "bottom" || conversations.first { $0.key == key }?.messages?.contains { $0.key == position } == true,
                            "present.scroll.\(key) is \"bottom\" or the key of a message in that conversation.")
            }
            for window in present.windows ?? [] {
                try require([window.conversation, window.activity, window.settings].compactMap({ $0 }).count == 1,
                            "A window is a conversation, a bot's activity or a settings tab.")
                if let key = window.conversation { try require(members[key] != nil, "present.windows names \"\(key)\", which does not exist.") }
                try require(window.frame.map { $0.count == 4 } ?? true, "A window frame is [x, y, width, height].")
                try require(window.settings.map { Self.settingsTabs[$0] != nil } ?? true, "\"\(window.settings ?? "")\" is not a settings tab.")
            }
            for key in [present.sheet?.editBot].compactMap({ $0 }) + (present.windows ?? []).compactMap(\.activity) {
                try require(agents.contains { $0.key == key }, "present names the bot \"\(key)\", which does not exist.")
            }
            if let sheet = present.sheet {
                let open = [sheet.newBot == true, sheet.newGroup == true, sheet.firstBotSetup == true, sheet.editBot != nil,
                            sheet.groupInfo != nil, sheet.background != nil].filter { $0 }.count
                try require(open <= 1, "Only one sheet can be open.")
            }
            // The main window marks the conversation it shows as read.
            if initial, conversations.contains(where: { $0.unread == true }) {
                try require(present.select.map { key in conversations.first { $0.key == key }?.unread != true } ?? false,
                            "With an unread conversation, present.select must name a conversation that is read.")
            }
        }
        try check(present ?? Presentation(), initial: true)

        for (index, step) in (timeline ?? []).enumerated() {
            let name = "timeline[\(index)]"
            try require(step.actions == 1 || (step.actions == 0 && step.wait != nil), "\(name) does one thing, or only waits.")
            try require((step.wait ?? 0) >= 0, "\(name) waits a negative time.")
            if let agent = step.agent { try require(agents.contains { $0.key == agent }, "\(name) names the bot \"\(agent)\", which does not exist.") }
            if let key = step.in { try require(members[key] != nil, "\(name) names the conversation \"\(key)\", which does not exist.") }
            let needsAgent = step.status != nil || step.reply != nil || step.stream != nil || step.toolCall != nil || step.waitFor == .userMessage
            try require(!needsAgent || step.agent != nil, "\(name) needs a bot.")
            try require(step.say == nil && step.type == nil || step.in != nil, "\(name) needs the conversation to speak in.")
            if let agent = step.agent, let key = step.in, step.reply != nil || step.react != nil {
                try require(members[key]?.contains(agent) == true, "\(name): \(agent) is not in \(key).")
            }
            try Self.check(step.status, of: name)
            let typing = step.type.map { Step.Content(key: $0.key, text: $0.text, attachments: $0.attachments) }
            for content in [step.reply, step.say, typing].compactMap({ $0 }) {
                try register(content.key)
                try require(!content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name) has no text.")
                try check(content.attachments)
            }
            try require((step.type?.interval ?? 0) >= 0, "\(name) types at a negative interval.")
            if let react = step.react {
                try require(messageKeys.contains(react.message), "\(name) reacts to \"\(react.message)\", which no earlier message is called.")
                try require(MessageReaction.isValidEmoji(react.emoji), "\"\(react.emoji)\" is not a single emoji.")
            }
            try require(step.stream.map { ($0.chunk ?? 1) > 0 && ($0.interval ?? 0) >= 0 } ?? true, "\(name) streams in chunks of at least one character.")
            try require(step.capture.map { !$0.isEmpty && !$0.contains("/") && !$0.contains(" ") } ?? true, "\(name): a shot name has no spaces or slashes.")
            try check(step.present, initial: false)
        }
    }

    private static func check(_ status: Status?, of owner: String) throws {
        guard let status else { return }
        if status.phase == .failed, status.detail?.isEmpty != false { throw ScenarioError("\(owner): a failed status says why in detail.") }
        if status.failure != nil, status.phase != .failed { throw ScenarioError("\(owner): only a failed status has a failure.") }
    }
}

// MARK: - Seed

extension Scenario {
    /// What the keys of a scenario became in the repository.
    struct Seeded {
        let clock: Date
        var agents: [String: AgentRecord] = [:]
        var conversations: [String: BotConversation] = [:]
        /// Every bot's direct conversation, by the bot's key, whether the scenario describes it or not.
        var directs: [String: BotConversation] = [:]
        var messages: [String: ChatMessage] = [:]
        var models: [HarnessProvider: [HarnessModel]] = [:]
        var executables: [HarnessProvider: URL] = [:]
        let discovery: HarnessDiscovery
    }

    func snapshot(_ status: Status?, for agent: AgentRecord) -> AgentRuntimeSnapshot {
        let name = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.displayName ?? "Harness"
        let status = status ?? Status(phase: .ready)
        let detail: String
        switch status.phase {
        case .ready: detail = "\(name) ready"
        case .working: detail = "Checking for new messages"
        case .starting: detail = "Starting \(name)"
        case .offline, .failed: detail = "Stopped"
        }
        let failure: AgentRuntimeFailure?
        switch status.failure {
        case .missingSession: failure = .missingSession("scenario")
        case .usageLimit: failure = .usageLimit
        case .authenticationRequired: failure = .authenticationRequired
        case .recoveryFailed: failure = .recoveryFailed
        case nil: failure = nil
        }
        return AgentRuntimeSnapshot(agentID: agent.id, phase: status.phase, detail: status.detail ?? detail, failure: failure)
    }

    func importAttachments(_ attachments: [Attachment]?, into conversationID: UUID, repository: WorkspaceRepository, now: Date) throws -> [UUID] {
        try (attachments ?? []).map { attachment in
            if let link = attachment.link, let url = URL(string: link) {
                return try repository.importLinkAttachment(url, into: conversationID, now: now).id
            }
            let url = try asset(attachment.file ?? "")
            let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return try repository.importAttachment(from: url, into: conversationID, mediaType: mediaType, now: now).id
        }
    }

    /// Replays the scenario into an empty repository and defaults domain. Harnesses become stub
    /// executables under `harnessHome`, laid out as harnesses Noodle installed: the sandbox refuses
    /// execute access inside the container, and only that kind is discovered without asking for it. Nothing runs them.
    @MainActor func seed(into repository: WorkspaceRepository, defaults: UserDefaults, harnessHome: URL, now: Date = Date()) throws -> Seeded {
        let files = FileManager.default
        let managed = ManagedHarnessStore(root: harnessHome)
        var seeded = Seeded(clock: try ScenarioSupport.start(clock, now: now),
            discovery: HarnessDiscovery(homeDirectory: harnessHome, applicationsDirectory: harnessHome,
                executableSearchDirectories: [], applicationBundleURL: harnessHome, managedHarnesses: managed, environment: [:]))
        for (key, value) in settings ?? [:] { defaults.set(value.propertyListValue, forKey: key) }
        defaults.set(MessageDeliveryMode.queue.rawValue, forKey: MessageDeliveryMode.defaultsKey)

        for provider in harnesses.keys.compactMap(HarnessProvider.init(rawValue:)) {
            guard let distribution = HarnessDistribution(provider) else { continue }
            let url = managed.directory.appendingPathComponent("\(provider.rawValue)/1.0.0/\(distribution.executablePath)")
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            guard let executable = managed.executable(provider) else { throw ScenarioError("Could not stand in for \(provider.displayName).") }
            seeded.executables[provider] = executable
            seeded.models[provider] = models(for: provider)
        }

        try repository.prepare()
        let created = seeded.clock.addingTimeInterval(-7 * 24 * 60 * 60)
        for (index, agent) in agents.enumerated() {
            let result = try repository.createAgent(named: agent.name, harnessIdentifier: agent.harness,
                modelIdentifier: agent.model, reasoningEffort: agent.effort, publicDescription: agent.description,
                avatarSymbolName: agent.avatar?.symbol, avatarColorIndex: agent.avatar?.colour ?? index,
                avatarImageData: try agent.avatar?.image.map { try Data(contentsOf: asset($0)) },
                backstory: agent.backstory ?? "", now: created.addingTimeInterval(Double(index) * 60))
            seeded.agents[agent.key] = result.agent
            seeded.directs[agent.key] = result.conversation
        }
        var access = AgentAccessConfiguration(autonomousAgentIDs: Set(agents.filter { $0.unrestricted == true }.compactMap { seeded.agents[$0.key]?.id }))
        for agent in seeded.agents.values { access.authorizeSelectedHarness(for: agent) }
        access.save(to: defaults)

        var unread = Set<UUID>()
        for entry in conversations ?? [] {
            var conversation: BotConversation
            if let group = entry.group {
                conversation = try repository.createGroup(named: group.name, publicDescription: group.description,
                    participantIDs: group.members.compactMap { seeded.agents[$0]?.id }, existingAgents: Array(seeded.agents.values), now: created)
            } else {
                conversation = seeded.directs[entry.direct ?? ""]!
            }
            for message in entry.messages ?? [] {
                let date = try ScenarioSupport.date(message.at, clock: seeded.clock)
                let author = message.from == "user" ? MessageAuthor.user : .agent(seeded.agents[message.from]!.id)
                let saved = ChatMessage(conversationID: conversation.id, author: author, body: message.text, createdAt: date,
                    delivery: message.delivery ?? .delivered,
                    attachmentIDs: try importAttachments(message.attachments, into: conversation.id, repository: repository, now: date))
                try repository.append(saved)
                for reaction in message.reactions ?? [] {
                    try repository.setReaction(conversationID: conversation.id, messageID: saved.id,
                        author: reaction.from == "user" ? .user : .agent(seeded.agents[reaction.from]!.id), emoji: reaction.emoji, present: true, now: date)
                }
                if let key = message.key { seeded.messages[key] = saved }
                conversation.updatedAt = date
            }
            try repository.updateConversation(conversation)
            if let preset = entry.background?.preset { try repository.setBackground(conversationID: conversation.id, preset: preset) }
            if let image = entry.background?.image {
                try repository.setBackground(conversationID: conversation.id, imageData: Data(contentsOf: asset(image)))
            }
            if entry.unread == true { unread.insert(conversation.id) }
            seeded.conversations[entry.key] = conversation
            if let key = entry.direct { seeded.directs[key] = conversation }
        }
        try repository.saveUnreadConversationIDs(unread)
        // Seeded history is already read: without this every bot is woken for it as it starts.
        for agent in seeded.agents.values { _ = try repository.latestMessages(for: agent.id) }

        // The app restores both files as it opens, keyed by the conversation identifiers made above.
        let positions = Dictionary(uniqueKeysWithValues: (present?.scroll ?? [:]).compactMap { key, position -> (UUID, TranscriptViewport)? in
            guard position != "bottom", let id = seeded.conversations[key]?.id, let message = seeded.messages[position] else { return nil }
            return (id, TranscriptViewport(offset: 0, isAtBottom: false, messageID: message.id))
        })
        try JSONEncoder().encode(positions).write(to: repository.rootURL.appendingPathComponent("scroll-positions.json"))
        let windows = (present?.windows ?? []).filter { $0.conversation != nil }
        let frames = Dictionary(uniqueKeysWithValues: windows.compactMap { window -> (UUID, String)? in
            guard let id = seeded.conversations[window.conversation ?? ""]?.id else { return nil }
            return (id, ScenarioSupport.frameDescriptor(window.frame ?? [160, 120, 760, 810]))
        })
        try JSONEncoder().encode(frames).write(to: repository.rootURL.appendingPathComponent("conversation-windows.json"))
        let floating = windows.filter { $0.floating == true }.compactMap { seeded.conversations[$0.conversation ?? ""]?.id.uuidString }
        if !floating.isEmpty { defaults.set(floating.sorted(), forKey: FloatingConversations.defaultsKey) }

        // Anything the format does not model, such as tool connections, is laid over the repository as files.
        let overlay = folder.appendingPathComponent("root", isDirectory: true)
        for path in (try? files.subpathsOfDirectory(atPath: overlay.path)) ?? [] {
            let source = overlay.appendingPathComponent(path), destination = repository.rootURL.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  !source.lastPathComponent.hasPrefix(".") else { continue }
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: destination)
            try files.copyItem(at: source, to: destination)
        }
        return seeded
    }
}

// MARK: - Scripted bot

/// Stands where a harness process would. It reports what the scenario says and runs nothing.
@MainActor final class ScenarioAgentProcess: AgentRuntimeProcess {
    let launch: AgentRuntimeLaunch
    private weak var session: ScenarioSession?
    var configuration: AgentRecord { launch.agent }
    private(set) var snapshot: AgentRuntimeSnapshot
    private(set) var isAlive = false
    let hasInterruptedWork = false
    let canReceiveHeartbeat = false
    /// Every wake the coordinator asked for, fetched or not.
    private(set) var notifications = 0

    init(_ launch: AgentRuntimeLaunch, session: ScenarioSession?) {
        self.launch = launch
        self.session = session
        snapshot = .init(agentID: launch.agent.id, phase: .offline, detail: "Not started")
    }

    func transition(_ snapshot: AgentRuntimeSnapshot) {
        self.snapshot = snapshot
        launch.onSnapshot(snapshot)
    }

    func start() {
        isAlive = true
        if let session { transition(session.startingSnapshot(for: launch.agent)) }
    }

    func stop(completion: @escaping (Bool) -> Void) {
        isAlive = false
        transition(.init(agentID: launch.agent.id, phase: .offline, detail: "Stopped"))
        completion(true)
    }

    /// A running harness fetches its unread messages, which is what turns Sent into Delivered.
    @discardableResult func notify(immediately: Bool) -> UUID {
        notifications += 1
        if let session, snapshot.phase == .ready || snapshot.phase == .working,
           let deliveries = try? session.repository.latestMessages(for: launch.agent.id),
           deliveries.contains(where: { $0.sender.handle == .user && $0.reactionChange == nil }) {
            session.userMessageArrived(for: launch.agent)
        }
        return UUID()
    }

    func promoteNotification(_ id: UUID) {}
    func heartbeat() {}
}

// MARK: - Session

/// One scenario in one app launch: seeds it, stands in for the harnesses, and plays the timeline.
@MainActor final class ScenarioSession {
    static let bundleIdentifier = "com.pdparchitect.noodle.scenarios"
    private(set) static var active: ScenarioSession?

    /// Where the timeline stops for someone outside the app.
    enum Pause { case key, userMessage(bot: String), shot(String) }

    let scenario: Scenario
    let seeded: Scenario.Seeded
    let repository: WorkspaceRepository
    let runtime: AgentRuntimeCoordinator
    private(set) var store: NoodleStore!
    /// Answers a pause in place of the menu and the terminal; false ends the timeline.
    var pause: (@MainActor (Pause) async -> Bool)?
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The timeline is stopped at `waitFor: key` until Next Step or a line from the terminal.
    var isWaitingForKey: Bool { !keyWaiters.isEmpty }
    /// A capture run: scripts/scenario.sh photographs each `capture` step and nobody is at the keyboard.
    var takesShots = false
    /// Marks a sound for the recording's track; tests replace it to count keystrokes.
    var soundCue: (@MainActor (String) -> Void)?
    /// Plays the titles around the timeline; tests replace it to watch the order without a window.
    var playFilm: (@MainActor (Scenario.Film.Stage) async throws -> Void)?
    private var filmStage: ScenarioFilmStage?
    private var processes: [UUID: ScenarioAgentProcess] = [:]
    private var started: Set<UUID> = []
    private var arrivals: [UUID: Int] = [:]
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var timelineEnded = false
    private var nextAutoReply: [UUID: Int] = [:]
    private var keyWaiters: [CheckedContinuation<Void, Never>] = []
    private var shotWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalEnded = true
    private var liveMessages: [String: ChatMessage] = [:]
    private var pickerWindow: NSWindow?
    /// What opened this scenario, a name or a path, which Reload opens again; nil while only the picker is open.
    private(set) var selection: String?
    private let launchedAt = Date()

    /// Scenarios replace the app's data, so they run only in the bundle scripts/scenario.sh derives,
    /// which has its own container and preferences and no network, account or group entitlement.
    static func isIsolated(bundleIdentifier: String?) -> Bool { bundleIdentifier == Self.bundleIdentifier }

    init(_ scenario: Scenario, root: URL, defaults: UserDefaults) throws {
        self.scenario = scenario
        repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle", isDirectory: true))
        seeded = try scenario.seed(into: repository, defaults: defaults, harnessHome: root.appendingPathComponent("Home", isDirectory: true))
        let seeded = seeded
        weak var session: ScenarioSession?
        runtime = AgentRuntimeCoordinator(discovery: seeded.discovery, defaults: defaults,
            makeProcess: { launch in
                let process = ScenarioAgentProcess(launch, session: session)
                session?.processes[launch.agent.id] = process
                return process
            },
            inspectHost: { provider in
                HarnessHostInspection(executablePath: seeded.executables[provider]?.path, models: seeded.models[provider] ?? [],
                    capabilityError: seeded.executables[provider] == nil ? "\(provider.displayName) is not installed" : nil)
            })
        session = self
        runtime.scriptedModels = seeded.models
        store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        if let message = store.errorMessage { throw ScenarioError(message) }
        apply(scenario.present ?? .init())
    }

    func process(for key: String) -> ScenarioAgentProcess? { seeded.agents[key].flatMap { processes[$0.id] } }

    /// The scenario's status the first time a bot starts; after a Kick it simply comes back ready.
    func startingSnapshot(for agent: AgentRecord) -> AgentRuntimeSnapshot {
        let first = started.insert(agent.id).inserted
        return scenario.snapshot(first ? scenario.agents.first { seeded.agents[$0.key]?.id == agent.id }?.status : nil, for: agent)
    }

    /// The scenario clock plus the time this launch has run, so live messages follow the seeded ones.
    var now: Date { seeded.clock.addingTimeInterval(Date().timeIntervalSince(launchedAt)) }

    func userMessageArrived(for agent: AgentRecord) {
        arrivals[agent.id, default: 0] += 1
        let waiters = arrivalWaiters
        arrivalWaiters = []
        waiters.forEach { $0.resume() }
        // Once the timeline has ended a bot answers from its own short script, in the conversation written to last.
        guard timelineEnded, let entry = scenario.agents.first(where: { seeded.agents[$0.key]?.id == agent.id }),
              let replies = entry.autoReplies, !replies.isEmpty,
              let conversation = try? repository.loadConversations().first(where: { $0.participantIDs.contains(agent.id) }) else { return }
        let text = replies[nextAutoReply[agent.id, default: 0] % replies.count]
        nextAutoReply[agent.id, default: 0] += 1
        Task { @MainActor in
            self.process(for: entry.key)?.transition(self.scenario.snapshot(.init(phase: .working), for: agent))
            try? await self.sleep(.seconds(1.5))
            _ = try? self.repository.sendAgentMessage(agentID: agent.id, conversationID: conversation.id, body: text, now: self.now)
            self.store.refreshTranscripts()
            self.process(for: entry.key)?.transition(self.scenario.snapshot(nil, for: agent))
        }
    }

    // MARK: Timeline

    func play() async throws {
        defer { timelineEnded = true }
        try await play(.intro)
        for step in scenario.timeline ?? [] {
            if let wait = step.wait, wait > 0 { try await sleep(.seconds(wait)) }
            guard try await perform(step) else { return }
        }
        try await play(.outro)
    }

    /// The titles. Their timings are fixed so every film opens and closes alike; a
    /// scenario chooses only the words and how long the finished card stays up.
    private func play(_ stage: Scenario.Film.Stage) async throws {
        guard let film = scenario.film else { return }
        if let playFilm { try await playFilm(stage); return }
        let card: ScenarioFilmModel.Card?, written: Double
        switch stage {
        case .intro:
            card = film.intro.map { .intro(kicker: $0.kicker, title: $0.title ?? scenario.title, subtitle: $0.subtitle, icon: icon(film.intro)) }
            written = 1.6 + (film.intro?.hold ?? 1.4)
        case .outro:
            card = film.outro.map { .outro(tagline: $0.tagline) }
            written = 3.3 + (film.outro?.hold ?? 1.6)
        }
        guard let card else {
            if stage == .outro { filmStage?.finish() }
            return
        }
        // The opening card is already up, from before the recorder started; presenting it
        // again only makes sure it is in front of the window it covers.
        filmStage?.present(card)
        // A frame with the card in its starting state, so its animations have something to run from.
        try await sleep(.milliseconds(60))
        filmStage?.model.written = true
        try await sleep(.seconds(written))
        // A recording ends on the wordmark; someone watching in the app gets their window back.
        if stage == .outro, takesShots { return }
        filmStage?.model.leaving = true
        try await sleep(.seconds(0.9))
        if stage == .intro { filmStage?.dismissCard() } else { filmStage?.finish() }
    }

    /// False when the timeline cannot go on.
    private func perform(_ step: Scenario.Step) async throws -> Bool {
        let agent = step.agent.flatMap { seeded.agents[$0] }
        let conversation = step.in.flatMap { seeded.conversations[$0] } ?? step.agent.flatMap { seeded.directs[$0] }
        if let status = step.status, let agent {
            process(for: step.agent ?? "")?.transition(scenario.snapshot(status, for: agent))
        }
        if let reply = step.reply, let agent, let conversation {
            let date = now
            let message = try repository.sendAgentMessage(agentID: agent.id, conversationID: conversation.id, body: reply.text,
                attachmentIDs: try scenario.importAttachments(reply.attachments, into: conversation.id, repository: repository, now: date), now: date)
            remember(message, as: reply.key)
            store.refreshTranscripts()
            cue("reply")
        }
        if let say = step.say, let conversation {
            let date = now
            let message = try repository.sendUserMessage(conversationID: conversation.id, body: say.text,
                attachmentIDs: try scenario.importAttachments(say.attachments, into: conversation.id, repository: repository, now: date), now: date)
            remember(message, as: say.key)
            store.refreshTranscripts()
            runtime.notify(store.participants(for: conversation), repository: repository)
        }
        if let typing = step.type, let conversation {
            var typed = ""
            for character in typing.text {
                typed.append(character)
                store.setDraft(typed, for: conversation.id)
                cue("key")
                // Keys land unevenly. Evenly spaced ones beat like a rotor once they have a sound.
                try await sleep(.seconds((typing.interval ?? 0.075) * Double.random(in: 0.55...1.65)))
            }
            // A beat with the whole message on screen, as a hand pauses before Return.
            try await sleep(.seconds(0.4))
            let date = now
            let message = try repository.sendUserMessage(conversationID: conversation.id, body: typing.text,
                attachmentIDs: try scenario.importAttachments(typing.attachments, into: conversation.id, repository: repository, now: date), now: date)
            store.setDraft("", for: conversation.id)
            remember(message, as: typing.key)
            store.refreshTranscripts()
            runtime.notify(store.participants(for: conversation), repository: repository)
        }
        if let react = step.react, let message = messages[react.message] {
            try repository.setReaction(conversationID: message.conversationID, messageID: message.id,
                author: agent.map { .agent($0.id) } ?? .user, emoji: react.emoji, present: react.remove != true, now: now)
            store.refreshTranscripts()
        }
        if let stream = step.stream, let agent {
            let log = runtime.activity.log(for: agent.id), id = "scenario-\(UUID().uuidString)"
            var rest = Substring(stream.text)
            while !rest.isEmpty {
                log.record(.init(title: "Output", detail: String(rest.prefix(stream.chunk ?? 12)), streamID: id, appending: true), at: now)
                rest = rest.dropFirst(stream.chunk ?? 12)
                try await sleep(.seconds(stream.interval ?? 0.05))
            }
        }
        if let call = step.toolCall, let agent {
            // The titles the activity parser gives a harness's own command events.
            let log = runtime.activity.log(for: agent.id), id = "scenario-\(UUID().uuidString)"
            log.record(.init(title: call.title ?? "Running command", detail: call.input, streamID: id), at: now)
            try await sleep(.seconds(call.duration ?? 0.8))
            if let exit = call.exit { log.record(.init(title: "Command completed (exit \(exit))", detail: call.input, streamID: id), at: now) }
            if let output = call.output { log.record(.init(title: "Tool output", detail: output, streamID: id + ":output"), at: now) }
        }
        if let error = step.error { store.errorMessage = error }
        if let present = step.present {
            apply(present)
            await arrangeWindows(present, initial: false)
        }
        switch step.waitFor {
        case .key: guard await answer(.key) else { return false }
        case .userMessage:
            guard let agent else { return true }
            let seen = arrivals[agent.id, default: 0]
            guard await answer(.userMessage(bot: step.agent ?? "")) else { return false }
            if takesShots, let id = conversation?.id {
                // Nobody types during a capture run, so the draft on screen is sent for them.
                guard !store.draft(for: id).isEmpty || !store.pendingAttachments(for: id).isEmpty else { break }
                store.sendDraft(to: id)
            }
            while arrivals[agent.id, default: 0] == seen { await withCheckedContinuation { arrivalWaiters.append($0) } }
        case nil: break
        }
        if let shot = step.capture { return await answer(.shot(shot)) }
        return true
    }

    /// The picture an opening card brings up, if it names one.
    private func icon(_ intro: Scenario.Film.Intro?) -> NSImage? {
        guard let path = intro?.icon, let url = try? scenario.asset(path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Tells whoever is recording that something just made a noise, and when. Only a
    /// capture run has a sound track to put it on.
    private func cue(_ name: String) {
        guard takesShots else { return }
        if let soundCue { soundCue(name); return }
        write("SCENARIO SOUND \(name) \(Date().timeIntervalSince1970)")
    }

    private var messages: [String: ChatMessage] { seeded.messages.merging(liveMessages) { $1 } }
    private func remember(_ message: ChatMessage, as key: String?) {
        if let key { liveMessages[key] = message }
    }

    /// Scenarios > Next Step, or a line from the terminal.
    func nextStep() {
        let waiters = keyWaiters
        keyWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func answer(_ pause: Pause) async -> Bool {
        if let answer = self.pause { return await answer(pause) }
        switch pause {
        case .userMessage: break
        case .key:
            // A capture run has nobody at the keyboard.
            guard !takesShots else { break }
            write("SCENARIO WAITING choose Scenarios > Next Step, or press Return here")
            await withCheckedContinuation { keyWaiters.append($0) }
        case .shot(let name):
            guard takesShots, !terminalEnded else { break }
            // Let the last change settle on screen before it is photographed.
            try? await Task.sleep(for: .milliseconds(700))
            guard let window = mainWindow, let region = mainWindowRegion else { break }
            write("SCENARIO SHOT \(name) id=\(window.windowNumber) rect=\(region)")
            await withCheckedContinuation { shotWaiters.append($0) }
        }
        return true
    }

    /// What `screencapture -R` should take: the film's stage if there is one, otherwise the
    /// main window. As x, y from the top left, width, height.
    private var mainWindowRegion: String? {
        guard let frame = filmStage.map(\.frame) ?? mainWindow?.frame, !frame.isEmpty else { return nil }
        return "\(Int(frame.minX)),\(Int(ScenarioSupport.screen.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
    }

    /// Ends a capture run. The script answers once its recorder has stopped, so the window is still up on the last frame.
    func announceDone() async {
        write("SCENARIO DONE")
        guard !terminalEnded else { return }
        await withCheckedContinuation { shotWaiters.append($0) }
    }

    /// Tells the script the window is up and where. A capture run waits for the answer, so a recording can start first.
    func announceReady() async {
        write("SCENARIO READY rect=\(mainWindowRegion ?? "none") \(scenario.title)")
        guard takesShots, !terminalEnded else { return }
        await withCheckedContinuation { shotWaiters.append($0) }
    }

    // MARK: Presentation

    /// The part of a presentation that is state in the store. Windows follow in `arrangeWindows`.
    func apply(_ present: Scenario.Presentation) {
        if let id = present.select.flatMap({ seeded.conversations[$0]?.id }) { store.selectedConversationID = id }
        if let search = present.search { store.searchText = search }
        if let id = store.selectedConversationID {
            if let draft = present.draft { store.setDraft(draft, for: id) }
            for path in present.draftAttachments ?? [] {
                if let url = try? scenario.asset(path) { store.importAttachment(from: url, into: id) }
            }
        }
        guard let sheet = present.sheet else { return }
        store.creationSheet = sheet.newBot == true ? .bot : (sheet.newGroup == true ? .group : nil)
        store.showsFirstBotSetup = sheet.firstBotSetup == true
        store.agentBeingEdited = sheet.editBot.flatMap { seeded.agents[$0] }
        store.groupBeingEdited = sheet.groupInfo.flatMap { seeded.conversations[$0] }
        store.backgroundBeingEdited = sheet.background.flatMap { seeded.conversations[$0] }
    }

    private var mainWindow: NSWindow? {
        NSApp?.windows.first { $0.title == NoodleAppIdentity.name && $0.contentViewController != nil && !($0 is NSPanel) }
    }

    /// Needs the running app. The first presentation's conversation windows were seeded, and the app restores them itself.
    func arrangeWindows(_ present: Scenario.Presentation, initial: Bool) async {
        for _ in 0..<100 where mainWindow == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard let window = mainWindow else { return }
        if let frame = present.window {
            let origin = frame.origin ?? [Double(window.frame.minX - ScenarioSupport.screen.minX), Double(ScenarioSupport.screen.maxY - window.frame.maxY)]
            window.setFrame(ScenarioSupport.rect([origin[0], origin[1], frame.size[0], frame.size[1]]), display: true)
        }
        if let sidebar = present.sidebar, let item = ScenarioSupport.splitController(in: window.contentView)?.splitViewItems.first {
            item.isCollapsed = sidebar == .hidden
        }
        for extra in present.windows ?? [] {
            if let agent = extra.activity.flatMap({ seeded.agents[$0] }) { store.showActivity(for: agent) }
            if let tab = extra.settings.flatMap({ Scenario.settingsTabs[$0] }) {
                store.selectedSettingsTab = tab
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            if !initial, let id = extra.conversation.flatMap({ seeded.conversations[$0]?.id }) {
                if extra.floating == true { store.floatConversation(id) } else { store.dockConversation(id) }
            }
        }
        if initial {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        if let film = scenario.film {
            let opening = film.intro.map { ScenarioFilmModel.Card.intro(kicker: $0.kicker, title: $0.title ?? scenario.title, subtitle: $0.subtitle, icon: icon($0)) }
            let stage = filmStage ?? ScenarioFilmStage(film: film, opening: opening)
            filmStage = stage
            stage.attach(to: window)
            if let opening { stage.present(opening) }
            if takesShots { stage.hidePointer() }
        }
    }

    // MARK: Terminal

    private func write(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }

    /// scripts/scenario.sh answers a shot with a newline once it is taken; at `waitFor: key` Return does what Next Step does.
    /// Launch Services attaches no terminal, so the lines end at once and only the menu is left.
    private func readTerminal() {
        terminalEnded = false
        Task { @MainActor in
            do {
                // Every newline counts, which the line sequence would not say of an empty line.
                for try await byte in FileHandle.standardInput.bytes where byte == 10 {
                    if let waiter = self.shotWaiters.first { self.shotWaiters.removeFirst(); waiter.resume() }
                    else { self.nextStep() }
                }
            } catch {}
            self.terminalEnded = true
            let waiters = self.shotWaiters
            self.shotWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
}

// MARK: - Launch, picker and menu

extension ScenarioSession {
    /// A folder under the scenarios root, as the picker and the menu list it. A scenario that does not load keeps its place and says why.
    struct Listing: Identifiable {
        let name: String
        let folder: URL
        let title: String
        let error: String?
        var id: String { name }
    }

    /// Where `scripts/scenario.sh` said the scenarios are.
    static var scenariosRoot: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "NoodleScenariosRoot") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Holds the name chosen in the app, in the container beside the run root. It stays until another choice replaces it,
    /// so Reload and opening the bundle again both return to the same scenario.
    static var pointerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("scenario-selection.txt")
    }

    static func listings(in root: URL?) -> [Listing] {
        guard let root, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("scenario.json")) else { return nil }
            do { return Listing(name: name, folder: folder.standardizedFileURL, title: try Scenario.load(from: folder).title, error: nil) }
            catch {
                let title = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["title"] as? String
                return Listing(name: name, folder: folder.standardizedFileURL, title: title ?? name, error: error.localizedDescription)
            }
        }
    }

    /// The launch argument first, then the choice made in the app, unless the launch asks for the picker.
    static func selection(_ checks: LaunchChecks, pointer: URL) -> String? {
        if let argument = checks.value(after: DevelopmentHook.scenario) { return argument }
        if checks.contains(DevelopmentHook.scenarioPicker) { return nil }
        let chosen = (try? String(contentsOf: pointer, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen?.isEmpty == false ? chosen : nil
    }

    static func select(_ name: String?, pointer: URL) throws {
        guard let name else { try? FileManager.default.removeItem(at: pointer); return }
        try FileManager.default.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: pointer, options: .atomic)
    }

    static func folder(for selection: String, root: URL?) -> URL? {
        selection.contains("/") ? URL(fileURLWithPath: selection, isDirectory: true) : root?.appendingPathComponent(selection, isDirectory: true)
    }

    /// The store for this launch, or nil outside the scenarios bundle, where the app opens as usual.
    static func launch(_ checks: LaunchChecks) -> NoodleStore? {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("SCENARIO FAILED \(message)\n".utf8))
            Darwin.exit(1)
        }
        let argument = checks.value(after: DevelopmentHook.scenario)
        guard isIsolated(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            if argument != nil { fail("Scenarios run only in the bundle scripts/scenario.sh makes (\(bundleIdentifier)).") }
            return nil
        }
        // Each launch starts from nothing: the last scenario's preferences and workspace are discarded.
        // A relaunch from the menu passes no arguments, so the locale the script asks for is kept here.
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: bundleIdentifier)
        defaults.set("en_US", forKey: "AppleLocale")
        defaults.set(["en"], forKey: "AppleLanguages")
        let runs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scenario", isDirectory: true)
        try? FileManager.default.removeItem(at: runs)

        func open(_ scenario: Scenario) throws -> ScenarioSession {
            // The instance this one replaces may still be writing as it quits, so no two launches share a folder.
            let session = try ScenarioSession(scenario, root: runs.appendingPathComponent(UUID().uuidString, isDirectory: true), defaults: defaults)
            active = session
            return session
        }

        if let selection = selection(checks, pointer: pointerURL) {
            do {
                guard let folder = folder(for: selection, root: scenariosRoot) else { throw ScenarioError("The bundle does not say where the scenarios are.") }
                let session = try open(Scenario.load(from: folder))
                session.selection = selection
                try? select(selection, pointer: pointerURL)
                session.takesShots = checks.contains(DevelopmentHook.scenarioShots)
                session.readTerminal()
                session.store.startMonitoring()
                Task { @MainActor in
                    await session.arrangeWindows(session.scenario.present ?? .init(), initial: true)
                    await session.announceReady()
                    do { try await session.play() } catch { fail(error.localizedDescription) }
                    if session.takesShots {
                        await session.announceDone()
                        NSApp.terminate(nil)
                    }
                }
                return session.store
            } catch {
                // The script is told. A choice made in the app goes back to the picker, which says what is wrong.
                if argument != nil { fail(error.localizedDescription) }
                try? select(nil, pointer: pointerURL)
            }
        }

        // Nothing is loaded: an empty workspace, with the picker standing in for the main window.
        var nothing = Scenario(version: 1, title: "Scenarios", harnesses: [:], agents: [])
        nothing.settings = [FirstBotSetup.dismissedKey: .bool(true)]
        do {
            let session = try open(nothing)
            Task { @MainActor in
                for _ in 0..<250 where session.mainWindow == nil { try? await Task.sleep(for: .milliseconds(20)) }
                session.mainWindow?.orderOut(nil)
                session.showPicker()
            }
            return session.store
        } catch { fail(error.localizedDescription) }
    }

    /// A sandboxed app cannot pass itself launch arguments, so the choice travels in the pointer file.
    /// Launch Services will not open a second instance of it either, so the bundle reopens once this one has quit.
    static func relaunch(into name: String?) {
        guard isIsolated(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        do {
            try select(name, pointer: pointerURL)
            let reopener = try reopener(of: Bundle.main.bundleURL, with: "/usr/bin/open")
            try reopener.process.run()
            whileRunning = reopener.whileRunning
            NSApp.terminate(nil)
        } catch { NSSound.beep() }
    }

    /// Held open until the app quits, which is what tells the reopener to go ahead.
    private static var whileRunning: FileHandle?

    /// A shell job in a process group of its own, so it outlives the app, that waits for `whileRunning` to close.
    static func reopener(of bundle: URL, with opener: String) throws -> (process: Process, whileRunning: FileHandle) {
        let pipe = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 3<&0; set -m; (cat <&3 > /dev/null; sleep 0.3; exec \"$0\" \"$1\") > /dev/null 2>&1 &", opener, bundle.path]
        process.standardInput = pipe
        return (process, pipe.fileHandleForWriting)
    }


    func showPicker() {
        if pickerWindow == nil {
            let controller = NSHostingController(rootView: ScenarioPicker(listings: Self.listings(in: Self.scenariosRoot)))
            // A window takes its title from its content view controller.
            controller.title = "Scenarios"
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 380))
            window.center()
            pickerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        pickerWindow?.makeKeyAndOrderFront(nil)
    }

    func revealInFinder() {
        guard let folder = selection == nil ? Self.scenariosRoot : scenario.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

private struct ScenarioPicker: View {
    let listings: [ScenarioSession.Listing]
    @State private var selection: String?

    private var canLoad: Bool { listings.contains { $0.name == selection && $0.error == nil } }

    var body: some View {
        VStack(spacing: 0) {
            List(listings, selection: $selection) { listing in
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.title)
                    Text(listing.error ?? listing.name)
                        .font(.caption)
                        .foregroundStyle(listing.error == nil ? Color.secondary : Color.red)
                }
                .padding(.vertical, 2)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { names in
                if let name = names.first, listings.contains(where: { $0.name == name && $0.error == nil }) { ScenarioSession.relaunch(into: name) }
            }
            .overlay {
                if listings.isEmpty { Text("No scenarios found").foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Load") { ScenarioSession.relaunch(into: selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canLoad)
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 260)
        .preferredColorScheme(.dark)
    }
}

/// The Scenarios menu, which only the scenarios bundle shows.
struct ScenarioCommands: Commands {
    var body: some Commands {
        if let session = ScenarioSession.active {
            CommandMenu("Scenarios") {
                ForEach(ScenarioSession.listings(in: ScenarioSession.scenariosRoot)) { listing in
                    Toggle(listing.title, isOn: Binding(get: { listing.folder.path == session.scenario.folder.path }, set: { _ in ScenarioSession.relaunch(into: listing.name) }))
                        .disabled(listing.error != nil)
                }
                Divider()
                Button("Reload") { ScenarioSession.relaunch(into: session.selection) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(session.selection == nil)
                Button("Next Step") { session.nextStep() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("Show Picker") { session.showPicker() }
                Button("Reveal in Finder") { session.revealInFinder() }
            }
        }
    }
}

// MARK: - Shared pieces
// Nothing below knows about Noodle's store or repository, so a companion app's loader can take it as it is.

enum ScenarioSupport {
    /// The clock a scenario opens at: `HH:mm` today, or the wall clock.
    static func start(_ clock: String?, now: Date, calendar: Calendar = .current) throws -> Date {
        guard let clock else { return now }
        guard !clock.contains(" "), !clock.hasPrefix("-") else { throw ScenarioError("clock is a time such as \"09:41\".") }
        return try date(clock, clock: now, calendar: calendar)
    }

    /// `HH:mm` on the scenario's day, `-Nd HH:mm` on an earlier day, or `-Nm` and `-Nh` before the clock.
    static func date(_ text: String, clock: Date, calendar: Calendar = .current) throws -> Date {
        func time(_ value: Substring, daysAgo: Int) -> Date? {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false).compactMap { Int($0) }
            guard value.count == 5, fields.count == 2, (0..<24).contains(fields[0]), (0..<60).contains(fields[1]),
                  let day = calendar.date(byAdding: .day, value: -daysAgo, to: clock) else { return nil }
            return calendar.date(bySettingHour: fields[0], minute: fields[1], second: 0, of: day)
        }
        func ago(_ value: Substring, _ unit: Character) -> Int? {
            value.first == "-" && value.last == unit ? Int(value.dropFirst().dropLast()).flatMap { $0 >= 0 ? $0 : nil } : nil
        }
        let parts = text.split(separator: " ")
        if parts.count == 1 {
            if let date = time(parts[0], daysAgo: 0) { return date }
            if let minutes = ago(parts[0], "m") { return clock.addingTimeInterval(-60 * Double(minutes)) }
            if let hours = ago(parts[0], "h") { return clock.addingTimeInterval(-3600 * Double(hours)) }
        } else if parts.count == 2, let days = ago(parts[0], "d"), let date = time(parts[1], daysAgo: days) {
            return date
        }
        throw ScenarioError("\"\(text)\" is not a time: use \"HH:mm\", \"-2d HH:mm\", \"-15m\" or \"-3h\".")
    }

    /// Keys of `original` that did not survive decoding and encoding again. Null values are skipped, as encoding omits them.
    static func unknownKeys(in original: Any, comparedTo encoded: Any?, path: String = "") -> [String] {
        if let original = original as? [String: Any] {
            let encoded = encoded as? [String: Any] ?? [:]
            return original.keys.sorted().flatMap { key -> [String] in
                guard !(original[key] is NSNull) else { return [] }
                let here = path.isEmpty ? key : "\(path).\(key)"
                return encoded[key] == nil ? [here] : unknownKeys(in: original[key]!, comparedTo: encoded[key], path: here)
            }
        }
        if let original = original as? [Any] {
            let encoded = encoded as? [Any] ?? []
            return original.enumerated().flatMap { index, value in
                unknownKeys(in: value, comparedTo: encoded.indices.contains(index) ? encoded[index] : nil, path: "\(path)[\(index)]")
            }
        }
        return []
    }

    static var screen: NSRect { NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080) }

    /// Scenario frames are `[x, y, width, height]` from the top left of the main screen.
    static func rect(_ frame: [Double]) -> NSRect {
        NSRect(x: screen.minX + frame[0], y: screen.maxY - frame[1] - frame[3], width: frame[2], height: frame[3])
    }

    /// The text form AppKit saves a window frame in, which is what conversation windows are restored from.
    static func frameDescriptor(_ frame: [Double]) -> String {
        let rect = rect(frame), screen = screen
        return [rect.minX, rect.minY, rect.width, rect.height, screen.minX, screen.minY, screen.width, screen.height]
            .map { String(Int($0)) }.joined(separator: " ") + " "
    }

    static func splitController(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController { return controller }
        return view.subviews.lazy.compactMap { splitController(in: $0) }.first
    }
}
#endif
