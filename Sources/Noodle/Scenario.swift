#if NOODLE_DEV_HOOKS
import HubLink
import AppKit
import Darwin
import NoodleBrand
import NoodleCore
import NoodleLaunchChecks
import SwiftUI
import UniformTypeIdentifiers
import NoodleRuntime

/// A screenshot scenario: `Scenarios/NAME/scenario.json`, replayed through the real repository with
/// scripted bots in place of harnesses. Development builds only.
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
        /// The bot's tasks as the scenario starts, oldest first.
        var tasks: [TaskEntry]?

        struct Avatar: Codable {
            var image: String?
            /// "white" or "black", for a mark that is drawn in the wrong one.
            var tint: String?
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
        /// Pinned in the order the conversations are listed.
        var pinned: Bool?
        var messages: [Message]?

        struct Group: Codable {
            var name: String
            var description: String?
            var members: [String]
        }

        struct Background: Codable {
            var preset: ConversationBackgroundPreset?
            /// An asset in the scenario folder, or a web address fetched into `.cache/`.
            var image: String?
            /// The same, for a wallpaper that moves.
            var video: String?
        }
    }

    /// A bot's task. `in` is a conversation key, the bot's own conversation when left out; `on` is
    /// "user" or a bot key, for a waiting task. In the timeline, a key seen before moves that task on.
    struct TaskEntry: Codable {
        var key: String?
        var title: String?
        var `in`: String?
        var state: AgentTask.State?
        var on: String?
        var note: String?
        var at: String?
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
        /// Conversations open as columns, left to right, in View › As Columns.
        var columns: [String]?
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
            /// The key of a message whose patch opens for review.
            var attachment: String?
            /// Files of that patch to tick off as viewed, and to open, by path.
            var viewed: [String]?
            var expanded: [String]?
        }

        /// Every sheet of the main window; the ones left out are closed.
        struct Sheet: Codable {
            var newBot: Bool?
            var newGroup: Bool?
            var editBot: String?
            var groupInfo: String?
            var background: String?
        }
    }

    typealias Film = ScenarioFilm

    struct Step: Codable {
        var wait: Double?
        var agent: String?
        var `in`: String?
        var status: Status?
        var task: TaskEntry?
        var reply: Content?
        var say: Content?
        var type: Typing?
        var react: React?
        var stream: Stream?
        var toolCall: ToolCall?
        var error: String?
        /// What the recording should move in on: "composer", "transcript" or "none".
        var focus: String?
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
            [status != nil, task != nil, reply != nil, say != nil, type != nil, react != nil, stream != nil, toolCall != nil, error != nil,
             focus != nil, waitFor != nil, present != nil, capture != nil].filter { $0 }.count
        }
    }
}

// MARK: - Load and validate

extension Scenario {
    /// `--scenario-size WIDTHxHEIGHT` opens the main window at that size instead of the scenario's own,
    /// so one scenario can be recorded in another shape without editing it.
    mutating func resize(_ checks: LaunchChecks) throws {
        guard let value = checks.value(after: DevelopmentHook.scenarioSize) else { return }
        let parts = value.split(separator: "x", omittingEmptySubsequences: false).map { Double($0) }
        guard parts.count == 2, let width = parts[0], let height = parts[1], width > 0, height > 0 else {
            throw ScenarioError("\(value) is not a window size like 1240x860.")
        }
        var present = self.present ?? .init()
        present.window = Presentation.Window(size: [width, height], origin: present.window?.origin)
        self.present = present
    }

    /// `--scenario-background`, `--scenario-without` and `--scenario-margin` change the film for one recording.
    mutating func adjustFilm(_ checks: LaunchChecks) throws {
        film = try ScenarioFilm.adjusted(film, background: checks.value(after: DevelopmentHook.scenarioBackground),
                                         without: checks.value(after: DevelopmentHook.scenarioWithout),
                                         margin: checks.value(after: DevelopmentHook.scenarioMargin), media: media)
    }

    static let tints = ScenarioFilm.tints
    static let focusRegions = ScenarioFilm.focusRegions

    static let settingsTabs: [String: NoodleSettingsTab] = [
        "general": .general, "chat": .chat, "harnesses": .harnesses, "bots": .bots, "groups": .groups, "mcps": .mcps,
        "keybindings": .keybindings, "permissions": .permissions, "companions": .companions, "updates": .updates
    ]

    /// Preferences a scenario may set. Message delivery is absent: the loader always queues, so the
    /// on-device classifier never runs.
    @MainActor static var preferenceKeys: Set<String> {
        [ChatAttachmentLayout.defaultsKey, BotNameStyle.defaultsKey, FirstBotSetup.dismissedKey,
         ComposerNameCompletion.descriptionsDefaultsKey, FloatingConversations.keepsOneDefaultsKey, ConversationListStyle.key,
         TaskListFilter.key]
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

    /// A picture or video a scenario names: an asset in its own folder, or a web address
    /// that scripts/scenario.sh has fetched into the `.cache` beside the scenarios. The
    /// bundle has no network of its own, so nothing is ever downloaded from in here.
    func media(_ value: String) throws -> URL {
        // The faces the app gives new bots, named rather than copied in beside the scenarios.
        if value.hasPrefix(Self.facePrefix) {
            guard let url = BotFaces.url(named: String(value.dropFirst(Self.facePrefix.count))) else {
                throw ScenarioError("Missing face: \(value)")
            }
            return url
        }
        return try ScenarioSupport.media(value, in: folder)
    }

    /// What names one of the app's built-in faces, as in "face:feminine-03".
    static let facePrefix = "face:"

    func asset(_ path: String) throws -> URL { try ScenarioSupport.file(path, under: folder) }

    /// The attachments of the message a scenario calls `key`, seeded or sent in its timeline.
    func attachments(ofMessage key: String) -> [Attachment] {
        for message in (conversations ?? []).flatMap({ $0.messages ?? [] }) where message.key == key { return message.attachments ?? [] }
        for step in timeline ?? [] {
            for content in [step.reply, step.say].compactMap({ $0 }) where content.key == key { return content.attachments ?? [] }
            if let typed = step.type, typed.key == key { return typed.attachments ?? [] }
        }
        return []
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
        _ = try ScenarioTime.start(clock, now: Date())
        try film?.validate(media: media)
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
            if let image = agent.avatar?.image { _ = try media(image) }
            try require(Self.tints.contains(agent.avatar?.tint ?? "none"), "\(agent.key): a tint is white or black.")
            try Self.check(agent.status, of: agent.key)
            for task in agent.tasks ?? [] { try self.check(task, of: agent.key, name: agent.key, new: true) }
        }

        var messageKeys = Set<String>()
        func register(_ key: String?) throws {
            guard let key else { return }
            try require(messageKeys.insert(key).inserted, "Message key \"\(key)\" is used twice.")
        }
        func check(_ attachments: [Attachment]?) throws {
            for attachment in attachments ?? [] {
                try require((attachment.file == nil) != (attachment.link == nil), "An attachment is either a file or a link.")
                if let file = attachment.file { _ = try media(file) }
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
                let named = [background.preset != nil, background.image != nil, background.video != nil].filter { $0 }
                try require(named.count == 1, "A background is a preset, an image or a video.")
                if let image = background.image { _ = try media(image) }
                if let video = background.video {
                    let file = try media(video)
                    try require(["mp4", "m4v", "mov"].contains(file.pathExtension.lowercased()),
                                "A background video is an mp4, m4v or mov, and \(file.lastPathComponent) is not.")
                }
            }
            var previous = Date.distantPast
            for message in conversation.messages ?? [] {
                try register(message.key)
                try require(message.from == "user" || participants.contains(message.from), "\(message.from) is not in \(conversation.key).")
                try require(!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "A message in \(conversation.key) has no text.")
                // A bot fetches a queued message as it starts, which would deliver it; `say` in the timeline sends one live.
                let allowed: [MessageDelivery] = message.from == "user" ? [.saved, .delivered, .failed] : [.delivered]
                try require(message.delivery.map(allowed.contains) ?? true, "\(conversation.key): a seeded message from \(message.from) cannot be \(message.delivery?.rawValue ?? "").")
                let date = try ScenarioTime.date(message.at, clock: Date())
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
            for key in [present.select, present.sheet?.groupInfo, present.sheet?.background].compactMap({ $0 }) + (present.scroll ?? [:]).keys + (present.columns ?? []) {
                try require(members[key] != nil, "present names the conversation \"\(key)\", which does not exist.")
            }
            if let key = present.sheet?.groupInfo { try require(conversations.first { $0.key == key }?.group != nil, "\(key) is not a group.") }
            try require(present.draft == nil && present.draftAttachments == nil || present.select != nil, "A draft needs present.select.")
            for path in present.draftAttachments ?? [] { _ = try media(path) }
            for (key, position) in present.scroll ?? [:] {
                try require(position == "bottom" || conversations.first { $0.key == key }?.messages?.contains { $0.key == position } == true,
                            "present.scroll.\(key) is \"bottom\" or the key of a message in that conversation.")
            }
            for window in present.windows ?? [] {
                try require([window.conversation, window.activity, window.settings, window.attachment].compactMap({ $0 }).count == 1,
                            "A window is a conversation, a bot's activity, a settings tab or a message's patch.")
                if let key = window.attachment {
                    try require(messageKeys.contains(key), "present.windows opens the patch of \"\(key)\", which no earlier message is called.")
                    let file = attachments(ofMessage: key).first?.file
                    try require(file.map { Patch.isPatchFile(name: $0, mediaType: "") } == true,
                                "present.windows opens the attachment of \"\(key)\", which is not a .patch or .diff file.")
                    try require(Patch(contentsOf: try asset(file ?? "")) != nil, "\(file ?? "") does not read as a patch.")
                }
                try require(window.attachment != nil || window.viewed == nil && window.expanded == nil,
                            "Only a window that opens a patch has files viewed or expanded.")
                if let key = window.conversation { try require(members[key] != nil, "present.windows names \"\(key)\", which does not exist.") }
                try require(window.frame.map { $0.count == 4 } ?? true, "A window frame is [x, y, width, height].")
                try require(window.settings.map { Self.settingsTabs[$0] != nil } ?? true, "\"\(window.settings ?? "")\" is not a settings tab.")
            }
            for key in [present.sheet?.editBot].compactMap({ $0 }) + (present.windows ?? []).compactMap(\.activity) {
                try require(agents.contains { $0.key == key }, "present names the bot \"\(key)\", which does not exist.")
            }
            if let sheet = present.sheet {
                let open = [sheet.newBot == true, sheet.newGroup == true, sheet.editBot != nil,
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
            if let task = step.task {
                try require(step.agent != nil && task.key != nil, "\(name): a task step names its bot and the task's key.")
                let known = agents.first { $0.key == step.agent }?.tasks?.contains { $0.key == task.key } == true
                    || (timeline ?? [])[..<index].contains { $0.agent == step.agent && $0.task?.key == task.key }
                try self.check(task, of: step.agent ?? "", name: name, new: !known)
            }
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
            try require(step.focus.map { Self.focusRegions.contains($0) } ?? true,
                        "\(name): focus is \(Self.focusRegions.sorted().joined(separator: ", ")).")
            try require(step.capture.map { !$0.isEmpty && !$0.contains("/") && !$0.contains(" ") } ?? true, "\(name): a shot name has no spaces or slashes.")
            try check(step.present, initial: false)
        }
    }

    /// Lays a moving wallpaper into the workspace the way the app would, without the
    /// picker's checks: a scenario's own files are already trusted.
    static func seedBackground(video url: URL, conversationID: UUID, repository: WorkspaceRepository) throws {
        let background = ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).\(url.pathExtension.lowercased())",
                                                mediaKind: .video)
        guard let target = repository.backgroundImageURL(background, conversationID: conversationID) else {
            throw ScenarioError("\(url.lastPathComponent) is not a wallpaper the app can keep.")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: target)
        let metadata = repository.conversationDirectory(id: conversationID).appendingPathComponent("background.json")
        try JSONEncoder().encode(background).write(to: metadata, options: .atomic)
    }

    private func check(_ task: TaskEntry, of agent: String, name: String, new: Bool) throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw ScenarioError(message) } }
        try require(!new || !(task.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name): a new task has a title.")
        if let key = task.in {
            try require(conversations?.first { $0.key == key }?.group?.members.contains(agent) == true
                        || conversations?.first { $0.key == key }?.direct == agent, "\(name): \(agent) is not in \(key).")
        }
        if let on = task.on {
            try require(on == "user" || agents.contains { $0.key == on }, "\(name): on is \"user\" or a bot key.")
            try require((task.state ?? .waiting) == .waiting, "\(name): only a waiting task waits on someone.")
        }
    }

    /// Adds a task the first time its key is seen and moves it on after that, as the bot would through Messenger.
    func apply(_ task: TaskEntry, of agentKey: String, seeded: Seeded, taskIDs: inout [String: UUID],
               repository: WorkspaceRepository, now: Date) throws {
        guard let agent = seeded.agents[agentKey] else { return }
        let waitingOn = task.on.map { $0 == "user" ? MessageAuthor.user : .agent(seeded.agents[$0]!.id) }
        let id: UUID
        if let key = task.key, let known = taskIDs[agentKey + "/" + key] {
            id = known
        } else {
            let conversation = task.in.flatMap { seeded.conversations[$0] } ?? seeded.directs[agentKey]
            id = try repository.addTask(agentID: agent.id, title: task.title ?? "", conversationID: conversation?.id,
                                        note: task.note, now: now).id
            if let key = task.key { taskIDs[agentKey + "/" + key] = id }
            guard task.state != nil || waitingOn != nil else { return }
        }
        _ = try repository.updateTask(agentID: agent.id, id: id, state: task.state ?? (waitingOn != nil ? .waiting : nil),
                                      waitingOn: waitingOn, title: task.title, note: task.note, now: now)
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
        /// Task IDs by "bot key/task key".
        var tasks: [String: UUID] = [:]
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
            let url = try media(attachment.file ?? "")
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
        var seeded = Seeded(clock: try ScenarioTime.start(clock, now: now),
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
                avatarImageData: try agent.avatar?.image.map { path in
                    let data = try Data(contentsOf: media(path))
                    guard let tint = agent.avatar?.tint, let image = NSImage(data: data) else { return data }
                    return ScenarioSupport.tinted(image, tint).tiffRepresentation ?? data
                },
                backstory: agent.backstory ?? "", now: created.addingTimeInterval(Double(index) * 60))
            seeded.agents[agent.key] = result.agent
            seeded.directs[agent.key] = result.conversation
        }
        var access = AgentAccessConfiguration(autonomousAgentIDs: Set(agents.filter { $0.unrestricted == true }.compactMap { seeded.agents[$0.key]?.id }))
        if !access.autonomousAgentIDs.isEmpty { defaults.set(true, forKey: AgentAccessConfiguration.unrestrictedAccessKey) }
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
                let date = try ScenarioTime.date(message.at, clock: seeded.clock)
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
                try repository.setBackground(conversationID: conversation.id, imageData: Data(contentsOf: media(image)))
            }
            if let video = entry.background?.video {
                try Self.seedBackground(video: try media(video), conversationID: conversation.id, repository: repository)
            }
            if entry.unread == true { unread.insert(conversation.id) }
            seeded.conversations[entry.key] = conversation
            if let key = entry.direct { seeded.directs[key] = conversation }
        }
        try repository.saveUnreadConversationIDs(unread)
        for agent in agents {
            for task in agent.tasks ?? [] {
                try apply(task, of: agent.key, seeded: seeded, taskIDs: &seeded.tasks, repository: repository,
                          now: try task.at.map { try ScenarioTime.date($0, clock: seeded.clock) } ?? seeded.clock)
            }
        }
        if let columns = present?.columns {
            defaults.set(MainWindowLayout.columns.rawValue, forKey: MainWindowLayout.key)
            defaults.set(["": columns.compactMap { seeded.conversations[$0]?.id.uuidString }], forKey: ColumnsModel.key)
        }
        try repository.savePinnedConversationIDs((conversations ?? []).filter { $0.pinned == true }.compactMap { seeded.conversations[$0.key]?.id })
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
    func wake() {}
    func organize() {}
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
    /// The seeded tasks and those the timeline added, by "bot key/task key".
    private lazy var taskIDs = seeded.tasks
    let repository: WorkspaceRepository
    let runtime: AgentRuntimeCoordinator
    private(set) var store: NoodleStore!
    /// Answers a pause in place of the menu and the terminal; false ends the timeline.
    var pause: (@MainActor (Pause) async -> Bool)?
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The timeline is stopped at `waitFor: key` until Next Step or a line from the terminal.
    var isWaitingForKey: Bool { terminal.isWaitingForKey }
    /// A capture run: scripts/scenario.sh photographs each `capture` step and nobody is at the keyboard.
    var takesShots = false {
        didSet {
            guard takesShots != oldValue else { return }
            // A key or click from whoever is passing the machine lands in the app and is filmed:
            // half a word in the composer, a menu open over the picture. An automated run is
            // driven from the timeline alone, so nothing else may reach it.
            if takesShots {
                inputMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.unwantedInput) { _ in nil }
            } else if let inputMonitor {
                NSEvent.removeMonitor(inputMonitor)
                self.inputMonitor = nil
            }
        }
    }

    /// What a capture run takes away from the app: everything a person could do to it by hand.
    static let unwantedInput: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel, .magnify, .swipe, .rotate,
    ]
    private var inputMonitor: Any?
    /// Whether the keyboard and mouse have been taken away from the app.
    var blocksInput: Bool { inputMonitor != nil }
    /// Marks a sound for the recording's track; tests replace it to count keystrokes.
    var soundCue: (@MainActor (String) -> Void)?
    /// Plays the titles around the timeline; tests replace it to watch the order without a window.
    var playFilm: (@MainActor (Scenario.Film.Stage) async throws -> Void)?
    private var filmStage: ScenarioFilmStage?
    /// What the recording is moving in on, so typing can keep the picture with it.
    private var focusRegion: String?
    private var processes: [UUID: ScenarioAgentProcess] = [:]
    private var started: Set<UUID> = []
    private var arrivals: [UUID: Int] = [:]
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var timelineEnded = false
    private var nextAutoReply: [UUID: Int] = [:]
    private let terminal = ScenarioTerminal()
    private var liveMessages: [String: ChatMessage] = [:]
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
        // Shots of a scenario that asks for dark look the same on a Mac set to light.
        if scenario.appearance == "dark" { NSApp?.appearance = NSAppearance(named: .darkAqua) }
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

    private func play(_ stage: Scenario.Film.Stage) async throws {
        // The titles are for the camera; someone watching gets straight to the timeline.
        guard takesShots, scenario.film != nil else { return }
        if let playFilm { try await playFilm(stage); return }
        try await filmStage?.play(stage, sleep: sleep)
    }

    /// Opens the scenario's windows, then runs the benchmark or, for a capture run, plays the timeline.
    /// Opened to look at, a scenario stays in its starting state, with nothing moving on its own.
    func start(benchmark: String?) async throws {
        await arrangeWindows(scenario.present ?? .init(), initial: true)
        await announceReady()
        if let benchmark, let window = mainWindow {
            await ScenarioBenchmark(session: self, phases: benchmark, window: window).run()
            NSApp.terminate(nil)
            return
        }
        guard takesShots else { return }
        try await play()
        await announceDone()
        NSApp.terminate(nil)
    }

    /// False when the timeline cannot go on.
    private func perform(_ step: Scenario.Step) async throws -> Bool {
        let agent = step.agent.flatMap { seeded.agents[$0] }
        let conversation = step.in.flatMap { seeded.conversations[$0] } ?? step.agent.flatMap { seeded.directs[$0] }
        if let status = step.status, let agent {
            process(for: step.agent ?? "")?.transition(scenario.snapshot(status, for: agent))
        }
        if let task = step.task, let agent {
            try scenario.apply(task, of: step.agent ?? "", seeded: seeded, taskIDs: &taskIDs, repository: repository, now: now)
            store.reloadTasks(of: agent.id)
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
                // The picture keeps up with the writing, letter by letter and at one
                // speed: eased steps would make it pulse rather than travel.
                if focusRegion == "composer" { cueFocus("composer", over: 0.15, steady: true) }
                // Keys land unevenly. Evenly spaced ones beat like a rotor once they have a sound.
                try await sleep(.seconds((typing.interval ?? 0.075) * Double.random(in: 0.55...1.65)))
            }
            // The picture pulls back as the hand reaches for Return, so the message
            // lands with the whole window in view.
            if focusRegion != nil {
                focusRegion = nil
                cueFocus("none", over: 0.5, steady: false)
            }
            // A beat with the whole message on screen, as a hand pauses before Return.
            try await sleep(.seconds(0.55))
            cue("enter")
            let date = now
            // Whatever the scenario put in the composer goes with the message, the way pressing
            // Return does, so a film can show a file being attached and then sent.
            let staged = store.pendingAttachments(for: conversation.id).map(\.id)
            let named = try scenario.importAttachments(
                typing.attachments, into: conversation.id, repository: repository, now: date)
            let message = try repository.sendUserMessage(conversationID: conversation.id, body: typing.text,
                attachmentIDs: staged + named, now: date)
            store.clearDraft(for: conversation.id)
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
        if let region = step.focus {
            focusRegion = region == "none" ? nil : region
            cueFocus(region, over: 0.9, steady: false)
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

    /// Tells whoever is recording what to move in on. The move itself is made afterwards, on the film.
    private func cueFocus(_ region: String, over move: Double, steady: Bool) {
        guard takesShots, let window = mainWindow,
              let line = ScenarioCue.focus(region, in: window, stage: filmStage, over: move, steady: steady) else { return }
        write(line)
    }

    /// Tells whoever is recording that something just made a noise, and when. Only a
    /// capture run has a sound track to put it on.
    private func cue(_ name: String) {
        guard takesShots else { return }
        if let soundCue { soundCue(name); return }
        write(ScenarioCue.sound(name))
    }

    private var messages: [String: ChatMessage] { seeded.messages.merging(liveMessages) { $1 } }
    private func remember(_ message: ChatMessage, as key: String?) {
        if let key { liveMessages[key] = message }
    }

    /// Scenarios > Next Step, or a line from the terminal.
    func nextStep() { terminal.nextStep() }

    private func answer(_ pause: Pause) async -> Bool {
        if let answer = self.pause { return await answer(pause) }
        switch pause {
        case .userMessage: break
        case .key:
            // A capture run has nobody at the keyboard.
            guard !takesShots else { break }
            write("SCENARIO WAITING choose Scenarios > Next Step, or press Return here")
            await terminal.awaitKey()
        case .shot(let name):
            guard takesShots, !terminal.ended else { break }
            // Let the last change settle on screen before it is photographed.
            try? await Task.sleep(for: .milliseconds(700))
            // A patch open for review is what the shot is of; otherwise the main window.
            guard let window = store.patchReviews.frontmost ?? mainWindow, let region = mainWindowRegion else { break }
            write("SCENARIO SHOT \(name) id=\(window.windowNumber) rect=\(region)")
            await terminal.awaitAnswer()
        }
        return true
    }

    private var mainWindowRegion: String? { ScenarioCue.region(stage: filmStage, window: mainWindow) }

    /// Ends a capture run. The script answers once its recorder has stopped, so the window is still up on the last frame.
    func announceDone() async {
        write("SCENARIO DONE")
        await terminal.awaitAnswer()
    }

    /// Tells the script the window is up and where. A capture run waits for the answer, so a recording can start first.
    func announceReady() async {
        write("SCENARIO READY rect=\(mainWindowRegion ?? "none") \(scenario.title)")
        guard takesShots else { return }
        await terminal.awaitAnswer()
    }

    // MARK: Presentation

    /// The part of a presentation that is state in the store. Windows follow in `arrangeWindows`.
    func apply(_ present: Scenario.Presentation) {
        if let id = present.select.flatMap({ seeded.conversations[$0]?.id }) { store.selectedConversationID = id }
        if let search = present.search { store.searchText = search }
        if let id = store.selectedConversationID {
            if let draft = present.draft { store.setDraft(draft, for: id) }
            for path in present.draftAttachments ?? [] {
                if let url = try? scenario.media(path) { store.importAttachment(from: url, into: id) }
            }
        }
        guard let sheet = present.sheet else { return }
        store.creationSheet = sheet.newBot == true ? .bot : (sheet.newGroup == true ? .group : nil)
        store.agentBeingEdited = sheet.editBot.flatMap { seeded.agents[$0] }
        store.groupBeingEdited = sheet.groupInfo.flatMap { seeded.conversations[$0] }
        store.backgroundBeingEdited = sheet.background.flatMap { seeded.conversations[$0] }
    }

    var mainWindow: NSWindow? {
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
            if let message = extra.attachment.flatMap({ messages[$0] }),
               let attachment = store.attachments(for: message).first(where: \.isPatchFile),
               let patch = PatchCache.patchNow(at: store.attachmentFileURL(attachment)) {
                if let viewed = extra.viewed { store.saveViewedPatchFiles(Set(viewed), for: attachment) }
                store.patchReviews.open(attachment, patch: patch, store: store, frame: extra.frame.map(ScenarioSupport.rect))
                store.patchReviews.model(for: attachment)?.expanded.formUnion(extra.expanded ?? [])
            }
        }
        if initial {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        // Only when the app first appears. A later presentation that set the film up again would
        // put the opening card back and leave the app concealed behind it for the rest of the film.
        // The backdrop and the cards are staged for a recording only; watched, the app stays on the desktop.
        if initial, takesShots, let film = scenario.film {
            let stage = filmStage ?? ScenarioFilmStage(film: film, title: scenario.title, media: scenario.media, mark: NoodleWordmark.filmMark)
            filmStage = stage
            stage.open(on: window)
        }
    }

    // MARK: Terminal

    private func write(_ line: String) { terminal.write(line) }

    /// scripts/scenario.sh answers a shot with a newline once it is taken; at `waitFor: key` Return does what Next Step does.
    private func readTerminal() { terminal.start() }
}

// MARK: - Launch, picker and menu

extension ScenarioSession {
    /// Where `scripts/scenario.sh` said the scenarios are.
    static var scenariosRoot: URL? { ScenarioLauncher.scenariosRoot(key: "NoodleScenariosRoot") }

    static func listings(in root: URL?) -> [ScenarioListing] {
        ScenarioLauncher.listings(in: root) { (try Scenario.load(from: $0).title, nil) }
    }

    /// The launch argument first, then the choice made in the app, unless the launch asks for the picker.
    static func selection(_ checks: LaunchChecks, pointer: URL) -> String? {
        ScenarioLauncher.selection(argument: checks.value(after: DevelopmentHook.scenario),
                                   picker: checks.contains(DevelopmentHook.scenarioPicker), pointer: pointer)
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

        if let selection = selection(checks, pointer: ScenarioLauncher.pointerURL) {
            do {
                guard let folder = ScenarioLauncher.folder(for: selection, root: scenariosRoot) else { throw ScenarioError("The bundle does not say where the scenarios are.") }
                var scenario = try Scenario.load(from: folder)
                try scenario.resize(checks)
                try scenario.adjustFilm(checks)
                let session = try open(scenario)
                session.selection = selection
                try? ScenarioLauncher.select(selection, pointer: ScenarioLauncher.pointerURL)
                session.takesShots = checks.contains(DevelopmentHook.scenarioShots)
                session.readTerminal()
                session.store.startMonitoring()
                let benchmark = checks.value(after: DevelopmentHook.scenarioBenchmark)
                    ?? (checks.contains(DevelopmentHook.scenarioBenchmark) ? "all" : nil)
                Task { @MainActor in
                    do { try await session.start(benchmark: benchmark) } catch { fail(error.localizedDescription) }
                }
                return session.store
            } catch {
                // The script is told. A choice made in the app goes back to the picker, which says what is wrong.
                if argument != nil { fail(error.localizedDescription) }
                try? ScenarioLauncher.select(nil, pointer: ScenarioLauncher.pointerURL)
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

    static func relaunch(into name: String?) {
        guard isIsolated(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
        ScenarioLauncher.relaunch(into: name)
    }

    func showPicker() { ScenarioLauncher.showPicker(Self.listings(in: Self.scenariosRoot)) }

    func revealInFinder() {
        guard let folder = selection == nil ? Self.scenariosRoot : scenario.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The Scenarios menu, which only the scenarios bundle shows.
struct ScenarioCommands: Commands {
    var body: some Commands {
        if let session = ScenarioSession.active {
            ScenarioMenu(listings: ScenarioSession.listings(in: ScenarioSession.scenariosRoot),
                         loaded: session.selection == nil ? nil : session.scenario.folder, selection: session.selection,
                         nextStep: session.nextStep, showPicker: session.showPicker, reveal: session.revealInFinder)
        }
    }
}

#endif
