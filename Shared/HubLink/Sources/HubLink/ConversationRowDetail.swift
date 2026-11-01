/// What the line under a bot's or group's name in the conversation list says.
public enum ConversationRowDetail: String, CaseIterable, Identifiable, Sendable {
    case latestMessage, description, status

    public static let key = "sidebarRowDetail"
    public static let standard = Self.latestMessage
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .latestMessage: "Latest Message"
        case .description: "Description"
        case .status: "Status"
        }
    }

    /// The line for a row: its latest message, or what the bot or group is for, or, as the widgets say, the status
    /// the bot set or else the start of its own latest reply. A group has a status per bot, so it keeps its latest
    /// message, as does a row without the other line.
    public func line(isGroup: Bool, description: String?, status: String?, latestReply: () -> String?,
                     latestMessage: String) -> String {
        func shown(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        switch self {
        case .latestMessage: return latestMessage
        case .description: return shown(description) ?? latestMessage
        case .status: return isGroup ? latestMessage : shown(status) ?? shown(latestReply()) ?? latestMessage
        }
    }
}
