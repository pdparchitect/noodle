import Foundation

/// A bot as Noodle's desktop widgets show it. The widget extension sees this and nothing else.
public struct WidgetBot: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var conversationID: UUID
    public var name: String
    public var symbol: String?
    public var colour: Int
    /// The avatar as Noodle draws it, as PNG. The shelf keeps it in a file of its own.
    public var image: Data? = nil
    public var status: String?
    public var isWorking: Bool
    /// When it last finished a turn.
    public var finishedAt: Date?

    public init(id: UUID, conversationID: UUID, name: String, symbol: String? = nil, colour: Int = 0, image: Data? = nil,
                status: String? = nil, isWorking: Bool = false, finishedAt: Date? = nil) {
        self.id = id; self.conversationID = conversationID; self.name = name; self.symbol = symbol; self.colour = colour
        self.image = image; self.status = status; self.isWorking = isWorking; self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey { case id, conversationID, name, symbol, colour, status, isWorking, finishedAt }
}

public enum WidgetBots {
    private static let linkHost = "conversation"

    /// Opens the bot's conversation in Noodle.
    public static func link(to bot: WidgetBot, scheme: String) -> URL {
        URL(string: "\(scheme)://\(linkHost)/\(bot.conversationID.uuidString.lowercased())")!
    }

    public static func conversationID(fromLink url: URL) -> UUID? {
        guard url.host == linkHost, url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.pathComponents[1])
    }

    /// The launcher's order, the sidebar's: pinned bots as they were pinned, then the rest as given.
    public static func launcher(_ bots: [WidgetBot], pinnedConversationIDs: [UUID]) -> [WidgetBot] {
        let pinned = pinnedConversationIDs.compactMap { id in bots.first { $0.conversationID == id } }
        return pinned + bots.filter { !pinnedConversationIDs.contains($0.conversationID) }
    }

    /// The status the bot set, or else the start of its latest reply, so a widget says what it last did.
    public static func statusLine(status: String?, messages: [ChatMessage], agentID: UUID,
                                  preview: (String) -> String) -> String? {
        if let status { return status }
        guard let reply = messages.last(where: { $0.author == .agent(agentID) }) else { return nil }
        let line = preview(reply.body).split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? nil : String(line.prefix(200))
    }

    /// Working bots first, then the most recently finished; bots that never worked are left out.
    public static func recent(_ bots: [WidgetBot]) -> [WidgetBot] {
        bots.filter { $0.isWorking || $0.finishedAt != nil }.enumerated().sorted { left, right in
            if left.element.isWorking != right.element.isWorking { return left.element.isWorking }
            let leftDate = left.element.finishedAt ?? .distantPast, rightDate = right.element.finishedAt ?? .distantPast
            return leftDate != rightDate ? leftDate > rightDate : left.offset < right.offset
        }.map(\.element)
    }

    /// Keeps finish times from the previous snapshot; a bot that was working then and is not now has just finished.
    public static func settle(_ bots: [WidgetBot], previous: [WidgetBot], now: Date) -> [WidgetBot] {
        let earlier = Dictionary(previous.map { ($0.id, $0) }) { first, _ in first }
        return bots.map { bot in
            var bot = bot
            let before = earlier[bot.id]
            let stopped = before?.isWorking == true && !bot.isWorking ? now : nil
            bot.finishedAt = [bot.finishedAt, before?.finishedAt, stopped].compactMap { $0 }.max()
            return bot
        }
    }
}

/// Where Noodle leaves its widgets' bots, in the app group it shares with its extensions. Every bot's picture is
/// a file of its own beside the list: a widget extension has little memory, and with every picture in the list it
/// read them all to show a few.
public struct BotWidgetShelf: Sendable {
    public let fileURL: URL
    private let picturesURL: URL

    public init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent("bots.json")
        picturesURL = rootURL.appendingPathComponent("Pictures", isDirectory: true)
    }

    #if canImport(Darwin)
    /// Widgets read the shelf through an app group.
    public static func configured(bundle: Bundle = .main) -> BotWidgetShelf? {
        guard let identifier = bundle.object(forInfoDictionaryKey: "NoodleSharedGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else { return nil }
        return BotWidgetShelf(rootURL: container.appendingPathComponent("Widgets", isDirectory: true))
    }
    #endif

    /// Every bot, without its picture.
    public func load() -> [WidgetBot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([WidgetBot].self, from: data)) ?? []
    }

    /// The bots with their pictures, for the few a widget shows.
    public func withPictures(_ bots: [WidgetBot]) -> [WidgetBot] {
        bots.map { bot in
            var bot = bot
            bot.image = try? Data(contentsOf: pictureURL(bot.id))
            return bot
        }
    }

    /// Returns whether anything changed, so widgets reload only then.
    @discardableResult
    public func save(_ bots: [WidgetBot]) throws -> Bool {
        let manager = FileManager.default
        try manager.createDirectory(at: picturesURL, withIntermediateDirectories: true)
        var changed = false
        // Pictures before the list, so a widget reading the new list finds them.
        for bot in bots {
            let url = pictureURL(bot.id)
            if let image = bot.image {
                guard (try? Data(contentsOf: url)) != image else { continue }
                try image.write(to: url, options: .atomic)
                changed = true
            } else if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
                changed = true
            }
        }
        let data = try Self.encoder.encode(bots)
        if (try? Data(contentsOf: fileURL)) != data {
            try data.write(to: fileURL, options: .atomic)
            changed = true
        }
        let kept = Set(bots.map { pictureURL($0.id).lastPathComponent })
        for url in (try? manager.contentsOfDirectory(at: picturesURL, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(url.lastPathComponent) {
            try? manager.removeItem(at: url)
        }
        return changed
    }

    private func pictureURL(_ id: UUID) -> URL { picturesURL.appendingPathComponent("\(id.uuidString.lowercased()).png") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
