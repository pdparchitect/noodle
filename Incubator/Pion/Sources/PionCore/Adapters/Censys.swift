import Foundation
import NoodleCore
import NoodleToolConnections

/// Censys: what an internet host exposes, from its Platform API, with a personal access token. check-access reads the
/// token's user's credits, which spends none.
///
/// The tool's guide is Incubator/Pion/docs/tools/threat-intel.md. Change it with the setup steps or operations here.
public enum Censys {
    public static let preset = ToolDefinition(
        id: "13aabe41-172d-44ff-b8aa-58fa152dc0f9", name: "Censys", summary: "What an internet-facing host exposes: services, software, network and location.",
        defaultInstructions: """
        Use Censys to see what an IP address exposes to the internet: its services and ports, network and owner, \
        location and DNS names, as Censys last scanned it. Record each lookup as evidence. Lookups never scan anything. \
        When a lookup is refused, run check-access and tell the champion exactly what it says to change.
        """,
        iconName: "censys",
        configuration: .connection(.init(endpoint: URL(string: "https://api.platform.censys.io/v3/global")!, tokenHeader: "Authorization",
                                  adapter: "censys")),
        setup: setup)

    static let setup = [
        "Sign in at [platform.censys.io](https://platform.censys.io), or create an account.",
        "In your account settings, open **Personal Access Tokens**, create a token and paste it here. Host lookups spend your account's credits. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Host(), CheckAccess()])
}

extension Censys {
    struct Host: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String }
        static let name = "host"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "An IP address's services and ports, network owner, location and DNS names."
        static let input = JSONSchema.object(["ip": .string("An IPv4 or IPv6 address.")], required: ["ip"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ip = try ServiceInput.ip(input.ip)
            struct System: Codable { let asn: Int?; let name: String? }
            struct Location: Codable { let country: String?; let city: String? }
            struct Service: Codable { let port: Int?; let `protocol`: String?; let transport_protocol: String? }
            struct DNS: Codable { let names: [String]? }
            struct Resource: Codable { let ip: String?, autonomous_system: System?, location: Location?, services: [Service]?, dns: DNS? }
            struct Result: Decodable { let resource: Resource? }
            struct Answer: Decodable { let result: Result? }
            guard let host = try await service.get(["asset", "host", ip], as: Answer.self).result?.resource else { throw ServiceError.unreadable }
            var text = "\(ip)"
            let about = [host.autonomous_system?.name, [host.location?.city, host.location?.country].compactMap { $0 }.joined(separator: ", ")]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !about.isEmpty { text += " (\(about.joined(separator: "; ")))" }
            let services = (host.services ?? []).map { "\($0.port.map(String.init) ?? "?")/\($0.protocol ?? $0.transport_protocol ?? "?")" }
            text += services.isEmpty ? ": no services seen." : ": " + services.joined(separator: ", ") + "."
            if let names = host.dns?.names, !names.isEmpty { text += " DNS: \(names.prefix(5).joined(separator: ", "))." }
            return try ServiceResult(text: text, structured: host)
        }
    }
}

extension Censys {
    static let fixes = AccessCheck.Fixes(
        rejected: "Censys did not accept the token: it is wrong, has expired or was revoked. Create a new personal access token in your Censys account settings and enter it again in Settings › Tools.",
        forbidden: "Censys refused the token for this: the account's plan may not include it.",
        rateLimited: "Censys is rate limiting this token: wait before trying again.")

    /// Reads the free credits of the user the token belongs to, which spends none.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the token once with a read of its user's credits, which spends none, and says how many are left and when they renew, or what to change."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(Censys.fixes)
            struct Credits: Decodable { let balance: Double?; let resets_at: String? }
            struct Answer: Decodable { let result: Credits? }
            await check.probe("Token") {
                let credits = try await service.at(host: service.base.host ?? "api.platform.censys.io")
                    .get(["v3", "accounts", "users", "credits"], as: Answer.self).result
                guard let balance = AccessCheck.whole(credits?.balance) else { return "it works" }
                return "it works; \(balance) credits are left\(credits?.resets_at.map { ", renewed \($0.prefix(10))" } ?? "")"
                    + (credits?.balance ?? 1 <= 0 ? ". Every host lookup is refused until then." : "")
            }
            check.note("Each host lookup spends one credit of the token's user.")
            return try check.result()
        }
    }
}
