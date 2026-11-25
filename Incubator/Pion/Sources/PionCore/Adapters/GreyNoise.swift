import Foundation
import NoodleCore
import NoodleToolConnections

/// GreyNoise: whether an IP address is background noise scanning the internet, or a known benign service.
/// check-access pings GreyNoise with the key, which spends no lookup, and only when the ping is refused tries one
/// Community lookup.
///
/// The tool's guide is Incubator/Pion/docs/tools/threat-intel.md. Change it with the setup steps or operations here.
public enum GreyNoise {
    public static let preset = ToolDefinition(
        id: "ea3b6b23-668e-4811-8bb6-a467ed70295f", name: "GreyNoise", summary: "Whether an IP address is mass-scanning the internet, or a known benign service.",
        defaultInstructions: """
        Use GreyNoise to tell targeted activity from background noise: whether an IP address has been scanning the whole \
        internet, whether it belongs to a known benign service such as a search engine or DNS resolver, and how GreyNoise \
        classifies it. An address GreyNoise has not seen scanning is worth more attention, not less. Record each lookup as \
        evidence. When a lookup is refused, run check-access and tell the champion exactly what it says to change.
        """,
        iconName: "greynoise",
        configuration: .connection(.init(endpoint: URL(string: "https://api.greynoise.io/v3")!, tokenHeader: "key", adapter: "greynoise")),
        setup: setup)

    static let setup = [
        "Sign in at [viz.greynoise.io](https://viz.greynoise.io), or create a free Community account.",
        "Open **Account › API Key**, copy the key and paste it here. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Context(), CheckAccess()])
}

extension GreyNoise {
    struct Context: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String }
        static let name = "ip-context"
        static let jobs: Set<ToolJob> = [.detection]
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

extension GreyNoise {
    static let fixes = AccessCheck.Fixes(
        rejected: "GreyNoise did not accept the key: it is wrong, has expired or was reset. Copy it again from Account › API Key and enter it in Settings › Tools.",
        forbidden: "GreyNoise refused the key for this: its plan may not include it.",
        rateLimited: "the key's lookups are used up for now: a free Community key allows about 50 a week, shared with the GreyNoise website. Wait, or use a paid plan.")

    /// Pings GreyNoise with the key, which spends no lookup and says the plan and when the key expires. A key the ping
    /// refuses is tried once more with a Community lookup of a known benign address, as the ping may not take a free key.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the key with GreyNoise's ping, which spends no lookup, and says its plan and when it expires, or what to change. Only when the ping is refused does it try one Community lookup, which spends one."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(GreyNoise.fixes)
            struct Pong: Decodable { let plan: String?; let expiration: String? }
            do {
                let pong = try await service.at(host: service.base.host ?? "api.greynoise.io").get(["ping"], as: Pong.self)
                let plan = pong.plan
                check.pass("API key", "it works" + (plan.map { ", on the \($0) plan" } ?? "") + (pong.expiration.map { ", until \($0)" } ?? ""))
                check.note("Lookups use the Community API, which a free key may call about 50 times a week.")
                return try check.result()
            } catch ServiceError.rejected, ServiceError.forbidden {
                // The ping may not take a Community key; one lookup tells a wrong key from that.
            } catch {
                check.fail("API key", check.fix(for: error))
                return try check.result()
            }
            struct Answer: Decodable { let riot: Bool? }
            await check.probe("API key (a Community lookup of 8.8.8.8, which spent one)") {
                _ = try await service.get(["community", "8.8.8.8"], as: Answer.self)
                return "it works for Community lookups; GreyNoise's ping does not take it"
            }
            return try check.result()
        }
    }
}
