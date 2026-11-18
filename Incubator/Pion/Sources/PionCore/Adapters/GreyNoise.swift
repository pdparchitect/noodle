import Foundation
import NoodleCore
import NoodleMCP

/// GreyNoise: whether an IP address is background noise scanning the internet, or a known benign service.
public enum GreyNoise {
    public static let preset = ToolDefinition(
        id: "ea3b6b23-668e-4811-8bb6-a467ed70295f", formerID: "greynoise", name: "GreyNoise", summary: "Whether an IP address is mass-scanning the internet, or a known benign service.",
        defaultInstructions: """
        Use GreyNoise to tell targeted activity from background noise: whether an IP address has been scanning the whole \
        internet, whether it belongs to a known benign service such as a search engine or DNS resolver, and how GreyNoise \
        classifies it. An address GreyNoise has not seen scanning is worth more attention, not less. Record each lookup as \
        evidence.
        """,
        iconName: "greynoise",
        configuration: .connection(.init(endpoint: URL(string: "https://api.greynoise.io/v3")!, tokenHeader: "key", adapter: "greynoise")),
        setup: setup)

    static let setup = [
        "Sign in at [viz.greynoise.io](https://viz.greynoise.io), or create a free Community account.",
        "Open **Account › API Key**, copy the key and paste it here.",
    ]

    public static let adapter = OperationAdapter(operations: [Context()])
}

extension GreyNoise {
    struct Context: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String }
        static let name = "ip-context"
        static let summary = "Whether an IP address is scanning the internet or is a known benign service, its classification and when last seen."
        static let input = JSONSchema.object(["ip": .string("An IPv4 address.")], required: ["ip"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ip = try ServiceInput.ip(input.ip)
            struct Answer: Codable {
                let ip: String?, noise: Bool?, riot: Bool?, classification: String?, name: String?, link: String?, last_seen: String?
            }
            let answer: Answer
            do { answer = try await service.get(["community", ip], as: Answer.self) }
            catch ServiceError.notFound {
                return try ServiceResult(text: "GreyNoise has not seen \(ip) scanning the internet, and it is not a known benign service.",
                                         structured: ["ip": ip, "seen": "false"])
            }
            var text = "\(ip): "
            if answer.riot == true { text += "a known benign service\(answer.name.map { " (\($0))" } ?? "")" }
            else if answer.noise == true { text += "seen scanning the internet" }
            else { text += "not seen scanning the internet" }
            if let classification = answer.classification { text += ", classified \(classification)" }
            if let seen = answer.last_seen { text += ", last seen \(seen)" }
            return try ServiceResult(text: text + ".", structured: answer)
        }
    }
}
