#if NOODLE_DEV_HOOKS
import Foundation
import NoodleBrand
import NoodleCore
#if canImport(NoodleDocument)
import NoodleDocument
#endif

/// A screenshot scenario: `Scenarios/NAME/scenario.json`, replayed through the real repository with
/// scripted bots in place of harnesses. The format, its checks and what it writes into a workspace are the
/// same for every app that plays it; the Mac app adds its windows, film and preferences. Development builds only.
public struct Scenario: Codable {
    public var version: Int
    public var title: String
    public var clock: String?
    public var appearance: String?
    public var settings: [String: Setting]?
    public var harnesses: [String: Harness]
    public var agents: [Agent]
    public var conversations: [Conversation]?
    public var present: Presentation?
    public var timeline: [Step]?
    public var film: Film?
    /// Where `scenario.json` was read; asset paths are relative to it.
    public var folder = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case version, title, clock, appearance, settings, harnesses, agents, conversations, present, timeline, film
    }

    public init(version: Int, title: String, clock: String? = nil, appearance: String? = nil, settings: [String: Setting]? = nil,
                harnesses: [String: Harness], agents: [Agent], conversations: [Conversation]? = nil, present: Presentation? = nil,
                timeline: [Step]? = nil, film: Film? = nil) {
        self.version = version
        self.title = title
        self.clock = clock
        self.appearance = appearance
        self.settings = settings
        self.harnesses = harnesses
        self.agents = agents
        self.conversations = conversations
        self.present = present
        self.timeline = timeline
        self.film = film
    }

    public enum Setting: Codable, Equatable {
        case bool(Bool), number(Double), text(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else { self = .text(try container.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .text(let value): try container.encode(value)
            }
        }

        public var propertyListValue: Any {
            switch self {
            case .bool(let value): return value
            case .number(let value): return value == value.rounded() ? Int(value) : value
            case .text(let value): return value
            }
        }
    }

    public struct Harness: Codable {
        /// `"builtin"` for Claude Code's fixed catalogue, otherwise the models the harness would report.
        public var models: Models

        public enum Models: Codable {
            case builtin, list([Model])

            public init(from decoder: Decoder) throws {
                if let models = try? [Model](from: decoder) { self = .list(models); return }
                guard try String(from: decoder) == "builtin" else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "models is \"builtin\" or a list"))
                }
                self = .builtin
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .builtin: try "builtin".encode(to: encoder)
                case .list(let models): try models.encode(to: encoder)
                }
            }
        }

        public struct Model: Codable {
            public var id: String
            public var name: String
            public var description: String?
            public var efforts: [String]?
            public var defaultEffort: String?
            public var `default`: Bool?
        }
    }

    public struct Agent: Codable {
        public var key: String
        public var name: String
        public var harness: String
        public var model: String?
        public var effort: String?
        public var description: String?
        public var backstory: String?
        public var avatar: Avatar?
        public var status: Status?
        public var unrestricted: Bool?
        public var autoReplies: [String]?
        /// The bot's tasks as the scenario starts, oldest first.
        public var tasks: [TaskEntry]?

        public struct Avatar: Codable {
            public var image: String?
            /// "white" or "black", for a mark that is drawn in the wrong one.
            public var tint: String?
            public var symbol: String?
            public var colour: Int?
        }
    }

    public struct Status: Codable {
        public var phase: AgentRuntimePhase
        public var detail: String?
        public var failure: Failure?

        public init(phase: AgentRuntimePhase, detail: String? = nil, failure: Failure? = nil) {
            self.phase = phase
            self.detail = detail
            self.failure = failure
        }

        public enum Failure: String, Codable {
            case missingSession, usageLimit, authenticationRequired, recoveryFailed
        }
    }

    public struct Conversation: Codable {
        public var key: String
        public var direct: String?
        public var group: Group?
        public var background: Background?
        public var unread: Bool?
        /// Pinned in the order the conversations are listed.
        public var pinned: Bool?
        public var messages: [Message]?

        public struct Group: Codable {
            public var name: String
            public var description: String?
            public var members: [String]
        }

        public struct Background: Codable {
            public var preset: ConversationBackgroundPreset?
            /// An asset in the scenario folder, or a web address fetched into `.cache/`.
            public var image: String?
            /// The same, for a wallpaper that moves.
            public var video: String?
        }
    }

    /// A bot's task. `in` is a conversation key, the bot's own conversation when left out; `on` is
    /// "user" or a bot key, for a waiting task. In the timeline, a key seen before moves that task on.
    public struct TaskEntry: Codable {
        public var key: String?
        public var title: String?
        public var `in`: String?
        public var state: AgentTask.State?
        public var on: String?
        public var note: String?
        public var at: String?
    }

    public struct Message: Codable {
        public var key: String?
        public var at: String
        public var from: String
        public var text: String
        public var delivery: MessageDelivery?
        public var attachments: [Attachment]?
        public var reactions: [Reaction]?
    }

    public struct Attachment: Codable {
        public var file: String?
        public var link: String?
        /// A browser tab or computer a bot shared, drawn from its picture as it was then.
        public var card: Card?

        public struct Card: Codable {
            public enum Kind: String, Codable { case browser, computer }
            public var kind: Kind
            public var title: String
            /// A browser tab's address; named "url" so the runner leaves it to show, not to fetch.
            public var url: String?
            /// A computer terminal's last output.
            public var detail: String?
            /// A JPEG of what it showed, under `LinkCard.maximumImageBytes`.
            public var picture: String?
        }
    }

    public struct Reaction: Codable {
        public var from: String
        public var emoji: String
    }

    public struct Presentation: Codable {
        public var window: Window?
        public var sidebar: Sidebar?
        public var select: String?
        /// Conversations open as columns, left to right, in View › As Columns.
        public var columns: [String]?
        public var search: String?
        public var draft: String?
        public var draftAttachments: [String]?
        public var scroll: [String: String]?
        public var windows: [ExtraWindow]?
        public var sheet: Sheet?

        public init(window: Window? = nil, sidebar: Sidebar? = nil, select: String? = nil, columns: [String]? = nil,
                    search: String? = nil, draft: String? = nil, draftAttachments: [String]? = nil, scroll: [String: String]? = nil,
                    windows: [ExtraWindow]? = nil, sheet: Sheet? = nil) {
            self.window = window
            self.sidebar = sidebar
            self.select = select
            self.columns = columns
            self.search = search
            self.draft = draft
            self.draftAttachments = draftAttachments
            self.scroll = scroll
            self.windows = windows
            self.sheet = sheet
        }

        public enum Sidebar: String, Codable { case visible, hidden }

        public struct Window: Codable {
            public var size: [Double]
            public var origin: [Double]?

            public init(size: [Double], origin: [Double]? = nil) {
                self.size = size
                self.origin = origin
            }
        }

        public struct ExtraWindow: Codable {
            public var conversation: String?
            public var frame: [Double]?
            public var floating: Bool?
            public var activity: String?
            public var settings: String?
            /// The key of a message whose patch opens for review, or whose Markdown or shader document opens.
            public var attachment: String?
            /// Files of that patch to tick off as viewed, and to open, by path.
            public var viewed: [String]?
            public var expanded: [String]?
            /// Shows the document's source rather than the document.
            public var source: Bool?
        }

        /// Every sheet of the main window; the ones left out are closed.
        public struct Sheet: Codable {
            public var newBot: Bool?
            public var newGroup: Bool?
            public var editBot: String?
            public var groupInfo: String?
            public var background: String?
        }
    }

    public typealias Film = ScenarioFilm

    public struct Step: Codable {
        public var wait: Double?
        public var agent: String?
        public var `in`: String?
        public var status: Status?
        public var task: TaskEntry?
        public var reply: Content?
        public var say: Content?
        public var type: Typing?
        public var react: React?
        public var stream: Stream?
        public var toolCall: ToolCall?
        public var error: String?
        /// What the recording should move in on: "composer", "transcript" or "none".
        public var focus: String?
        public var waitFor: Wait?
        public var present: Presentation?
        public var capture: String?

        public enum Wait: String, Codable { case userMessage, key }

        public struct Content: Codable {
            public var key: String?
            public var text: String
            public var attachments: [Attachment]?
        }

        /// A message typed into the composer a character at a time, then sent.
        public struct Typing: Codable {
            public var key: String?
            public var text: String
            public var attachments: [Attachment]?
            public var interval: Double?
        }

        public struct React: Codable {
            public var message: String
            public var emoji: String
            public var remove: Bool?
        }

        public struct Stream: Codable {
            public var text: String
            public var chunk: Int?
            public var interval: Double?
        }

        public struct ToolCall: Codable {
            public var title: String?
            public var input: String
            public var output: String?
            public var exit: Int?
            public var duration: Double?
        }

        public var actions: Int {
            [status != nil, task != nil, reply != nil, say != nil, type != nil, react != nil, stream != nil, toolCall != nil, error != nil,
             focus != nil, waitFor != nil, present != nil, capture != nil].filter { $0 }.count
        }
    }
}

// MARK: - Load and validate

extension Scenario {
    public static let tints = ScenarioFilm.tints
    public static let focusRegions = ScenarioFilm.focusRegions

    /// Strict: a key the model does not know is an error, so a typo cannot silently change a screenshot.
    /// `preferenceKeys` are the preferences the playing app lets a scenario set, and `settingsTabs` the settings tabs it can
    /// open in a window; nil leaves that check to an app that has them.
    public static func load(from folder: URL, preferenceKeys: Set<String>?, settingsTabs: Set<String>?) throws -> Scenario {
        let file = folder.appendingPathComponent("scenario.json")
        guard let data = try? Data(contentsOf: file) else { throw ScenarioError("There is no scenario at \(file.path).") }
        var scenario: Scenario
        do { scenario = try JSONDecoder().decode(Scenario.self, from: data) }
        catch let error as DecodingError { throw ScenarioError("\(file.lastPathComponent): \(Self.describe(error))") }
        let unknown = ScenarioSupport.unknownKeys(in: try JSONSerialization.jsonObject(with: data),
            comparedTo: try JSONSerialization.jsonObject(with: JSONEncoder().encode(scenario)))
        guard unknown.isEmpty else { throw ScenarioError("Unknown keys in \(file.lastPathComponent): \(unknown.joined(separator: ", "))") }
        scenario.folder = folder.standardizedFileURL
        try scenario.validate(preferenceKeys: preferenceKeys, settingsTabs: settingsTabs)
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
    public func media(_ value: String) throws -> URL {
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
    public static let facePrefix = "face:"

    public func asset(_ path: String) throws -> URL { try ScenarioSupport.file(path, under: folder) }

    /// The attachments of the message a scenario calls `key`, seeded or sent in its timeline.
    public func attachments(ofMessage key: String) -> [Attachment] {
        for message in (conversations ?? []).flatMap({ $0.messages ?? [] }) where message.key == key { return message.attachments ?? [] }
        for step in timeline ?? [] {
            for content in [step.reply, step.say].compactMap({ $0 }) where content.key == key { return content.attachments ?? [] }
            if let typed = step.type, typed.key == key { return typed.attachments ?? [] }
        }
        return []
    }

    public func models(for provider: HarnessProvider) -> [HarnessModel] {
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

    /// Whether a file a window opens is a document, Markdown or a shader, rather than a patch.
    static func isDocument(_ file: String) -> Bool {
        #if canImport(NoodleDocument)
        let markdown = MarkdownDocument.isMarkdown(name: file, mediaType: "")
        #else
        // NoodleDocument draws with Apple's Markdown, so where it does not build only the name is read, as it reads it.
        let markdown = ["md", "markdown", "mdown", "mkd", "mkdn"].contains(URL(fileURLWithPath: file).pathExtension.lowercased())
        #endif
        #if canImport(Metal) && canImport(CoreGraphics)
        let shader = ShaderSourceFile.isShader(URL(fileURLWithPath: file))
        #else
        // Shaders run on Metal; elsewhere one is still told by its name, as ShaderSourceFile tells it.
        let shader = URL(fileURLWithPath: file).pathExtension.lowercased() == "metal"
        #endif
        return markdown || shader
    }

    public func validate(preferenceKeys: Set<String>?, settingsTabs: Set<String>?) throws {
        func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition { throw ScenarioError(message()) }
        }
        try require(version == 1, "Scenario version \(version) is not supported.")
        try require(appearance == nil || appearance == "dark", "Noodle is dark only: appearance must be \"dark\" or left out.")
        _ = try ScenarioTime.start(clock, now: Date())
        try film?.validate(media: media)
        if let preferenceKeys {
            for key in (settings ?? [:]).keys {
                try require(preferenceKeys.contains(key), "\"\(key)\" is not a preference a scenario can set.")
            }
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
                try require([attachment.file != nil, attachment.link != nil, attachment.card != nil].filter { $0 }.count == 1,
                            "An attachment is a file, a link or a card.")
                if let file = attachment.file { _ = try media(file) }
                if let picture = attachment.card?.picture {
                    let size = (try? media(picture).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                    try require(size <= LinkCard.maximumImageBytes, "\(picture) is over \(LinkCard.maximumImageBytes) bytes.")
                }
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
                            "A window is a conversation, a bot's activity, a settings tab or a message's patch or document.")
                if let key = window.attachment {
                    try require(messageKeys.contains(key), "present.windows opens the attachment of \"\(key)\", which no earlier message is called.")
                    let file = attachments(ofMessage: key).first?.file
                    let isDocument = file.map(Self.isDocument) == true
                    try require(isDocument || file.map { Patch.isPatchFile(name: $0, mediaType: "") } == true,
                                "present.windows opens the attachment of \"\(key)\", which is not a patch, Markdown or shader file.")
                    try require(isDocument || Patch(contentsOf: try asset(file ?? "")) != nil, "\(file ?? "") does not read as a patch.")
                    try require(!isDocument || window.viewed == nil && window.expanded == nil,
                                "Only a window that opens a patch has files viewed or expanded.")
                    try require(isDocument || window.source == nil, "Only a window that opens a document shows its source.")
                }
                try require(window.attachment != nil || window.viewed == nil && window.expanded == nil && window.source == nil,
                            "Only a window that opens a patch has files viewed or expanded, and only a document shows its source.")
                if let key = window.conversation { try require(members[key] != nil, "present.windows names \"\(key)\", which does not exist.") }
                try require(window.frame.map { $0.count == 4 } ?? true, "A window frame is [x, y, width, height].")
                if let settingsTabs {
                    try require(window.settings.map { settingsTabs.contains($0) } ?? true, "\"\(window.settings ?? "")\" is not a settings tab.")
                }
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
    public static func seedBackground(video url: URL, conversationID: UUID, repository: WorkspaceRepository) throws {
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
    public func apply(_ task: TaskEntry, of agentKey: String, seeded: Seeded, taskIDs: inout [String: UUID],
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
    public struct Seeded {
        public let clock: Date
        public var agents: [String: AgentRecord] = [:]
        public var conversations: [String: BotConversation] = [:]
        /// Every bot's direct conversation, by the bot's key, whether the scenario describes it or not.
        public var directs: [String: BotConversation] = [:]
        public var messages: [String: ChatMessage] = [:]
        /// Task IDs by "bot key/task key".
        public var tasks: [String: UUID] = [:]
        public var models: [HarnessProvider: [HarnessModel]] = [:]
        public var executables: [HarnessProvider: URL] = [:]
        public let discovery: HarnessDiscovery

        public init(clock: Date, discovery: HarnessDiscovery) {
            self.clock = clock
            self.discovery = discovery
        }
    }

    public func snapshot(_ status: Status?, for agent: AgentRecord) -> AgentRuntimeSnapshot {
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

    public func importAttachments(_ attachments: [Attachment]?, into conversationID: UUID, repository: WorkspaceRepository, now: Date) throws -> [UUID] {
        try (attachments ?? []).map { attachment in
            if let link = attachment.link, let url = URL(string: link) {
                return try repository.importLinkAttachment(url, into: conversationID, now: now).id
            }
            if let card = attachment.card {
                let link: CompanionLink = card.kind == .browser ? .browser(UUID(), tab: UUID()) : .computer(UUID(), terminal: nil, view: nil)
                let picture = try card.picture.map { try Data(contentsOf: media($0)) }
                return try repository.importLinkAttachment(link.url, into: conversationID, now: now,
                    card: LinkCard(title: card.title, detail: card.url ?? card.detail, image: picture, capturedAt: now)).id
            }
            let url = try media(attachment.file ?? "")
            let mediaType = Pictures.mediaType(forFilenameExtension: url.pathExtension) ?? "application/octet-stream"
            return try repository.importAttachment(from: url, into: conversationID, mediaType: mediaType, now: now).id
        }
    }

    /// Writes the scenario's bots, conversations, messages, reactions, backgrounds, unread and pinned conversations, tasks
    /// and scroll positions into `repository`, recording what each key became in `seeded`. `avatar` may redraw a bot's
    /// picture, as for a tint, before it is kept. Whatever the app keeps outside the repository is the app's to seed.
    public func seedStore(into repository: WorkspaceRepository, seeded: inout Seeded,
                          avatar: (Agent, Data) -> Data = { $1 }) throws {
        try repository.prepare()
        let created = seeded.clock.addingTimeInterval(-7 * 24 * 60 * 60)
        for (index, agent) in agents.enumerated() {
            let result = try repository.createAgent(named: agent.name, harnessIdentifier: agent.harness,
                modelIdentifier: agent.model, reasoningEffort: agent.effort, publicDescription: agent.description,
                avatarSymbolName: agent.avatar?.symbol, avatarColorIndex: agent.avatar?.colour ?? index,
                avatarImageData: try agent.avatar?.image.map { path in avatar(agent, try Data(contentsOf: media(path))) },
                backstory: agent.backstory ?? "", now: created.addingTimeInterval(Double(index) * 60))
            seeded.agents[agent.key] = result.agent
            seeded.directs[agent.key] = result.conversation
        }

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
        try repository.savePinnedConversationIDs((conversations ?? []).filter { $0.pinned == true }.compactMap { seeded.conversations[$0.key]?.id })
        // Seeded history is already read: without this every bot is woken for it as it starts.
        for agent in seeded.agents.values { _ = try repository.latestMessages(for: agent.id) }

        // The app restores this as it opens, keyed by the conversation identifiers made above.
        let positions = Dictionary(uniqueKeysWithValues: (present?.scroll ?? [:]).compactMap { key, position -> (UUID, TranscriptViewport)? in
            guard position != "bottom", let id = seeded.conversations[key]?.id, let message = seeded.messages[position] else { return nil }
            return (id, TranscriptViewport(offset: 0, isAtBottom: false, messageID: message.id))
        })
        try JSONEncoder().encode(positions).write(to: repository.rootURL.appendingPathComponent("scroll-positions.json"))
    }

    /// Anything the format does not model, such as tool connections, is laid over the repository as files from the
    /// scenario's `root` folder. The last thing a seed does, so those files win.
    public func applyOverlay(to repository: WorkspaceRepository) throws {
        let files = FileManager.default
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
    }
}
#endif
