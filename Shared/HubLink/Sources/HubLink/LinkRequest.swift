import Foundation

/// A request one bot asked another, as the conversation it came from shows it. Someone the bot is
/// shared with gets only the helper's name and how it went, without the request or the answer.
public struct LinkRequestLine: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case waiting, answered, cancelled, expired, withheld }

    public var helperName: String
    public var status: Status
    public var text: String?
    public var answer: String?

    public init(helperName: String, status: Status, text: String? = nil, answer: String? = nil) {
        self.helperName = helperName
        self.status = status
        self.text = text
        self.answer = answer
    }
}
