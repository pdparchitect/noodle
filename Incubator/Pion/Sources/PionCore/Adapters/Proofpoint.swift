import Foundation
import NoodleCore
import NoodleMCP

/// Proofpoint Targeted Attack Protection: the threats in mail it delivered or blocked, and the clicks on them,
/// read with a service principal and its secret.
public enum Proofpoint {
    public static let preset = ToolDefinition(
        id: "proofpoint", name: "Proofpoint TAP", summary: "Malicious messages delivered and blocked, and who clicked their links.",
        defaultInstructions: """
        Use Proofpoint TAP to see the email threats of the last hour: messages with threats that were delivered or \
        blocked, with sender, recipients, subject and the threat; and clicks on threat links that were permitted or \
        blocked, with who clicked and from where. Record each finding as evidence. These tools only read: recommend \
        pulling a message or blocking a sender to the champion.
        """,
        iconName: "proofpoint",
        configuration: .connection(.init(endpoint: URL(string: "https://tap-api-v2.proofpoint.com/v2")!, tokenHeader: "Authorization", tokenScheme: "Basic",
                                  composedToken: ComposedToken(first: "Service Principal", second: "Secret", format: .basic), adapter: "proofpoint")),
        setup: setup)

    static let setup = [
        "In the TAP Dashboard, open **Settings › Connected Applications** and choose **Create New Credential**.",
        "Name it, such as Pion, and copy the **Service Principal** and **Secret** here; the secret is shown only once.",
    ]

    public static let adapter = OperationAdapter(operations: [SIEMEvents()])
}

extension Proofpoint {
    struct SIEMEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let minutes: Int? }
        static let name = "siem-events"
        static let summary = "Threat messages delivered and blocked, and clicks on threat links permitted and blocked, over the last minutes, up to an hour."
        static let input = JSONSchema.object(["minutes": .integer("How far back, in minutes. 60 when left out.", minimum: 1, maximum: 60)])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let minutes = input.minutes ?? 60
            guard (1...60).contains(minutes) else { throw ServiceError.input("Look back between 1 and 60 minutes.") }
            struct Threat: Codable { let threat: String?, classification: String?, threatStatus: String? }
            struct Message: Codable {
                let messageTime: String?, sender: String?, recipient: [String]?, subject: String?, senderIP: String?, threatsInfoMap: [Threat]?
            }
            struct Click: Codable { let clickTime: String?, recipient: String?, url: String?, classification: String?, clickIP: String? }
            struct Answer: Codable { let messagesDelivered: [Message]?, messagesBlocked: [Message]?, clicksPermitted: [Click]?, clicksBlocked: [Click]? }
            let answer = try await service.get(["siem", "all"], query: ["format": "json", "sinceSeconds": String(minutes * 60)], as: Answer.self)
            func message(_ item: Message, _ outcome: String) -> String {
                let threats = (item.threatsInfoMap ?? []).map { "\($0.classification ?? "threat") \($0.threat ?? "")" }
                return "\(item.messageTime ?? "?") \(outcome): \"\(item.subject ?? "")\" from \(item.sender ?? "?")\(item.senderIP.map { " (\($0))" } ?? "") to \((item.recipient ?? []).joined(separator: ", ")) — \(threats.joined(separator: "; "))"
            }
            func click(_ item: Click, _ outcome: String) -> String {
                "\(item.clickTime ?? "?") \(item.recipient ?? "?") clicked \(item.url ?? "?") (\(item.classification ?? "threat"), \(outcome))\(item.clickIP.map { " from \($0)" } ?? "")"
            }
            let lines = (answer.messagesDelivered ?? []).map { message($0, "delivered") } + (answer.messagesBlocked ?? []).map { message($0, "blocked") }
                + (answer.clicksPermitted ?? []).map { click($0, "permitted") } + (answer.clicksBlocked ?? []).map { click($0, "blocked") }
            let text = lines.isEmpty ? "No threats in the last \(minutes) minutes." : lines.prefix(40).joined(separator: "\n")
            return try ServiceResult(text: text, structured: answer)
        }
    }
}
