import Foundation
import NoodleCore
import NoodleMCP

/// Censys: what an internet host exposes, from its Platform API, with a personal access token.
public enum Censys {
    public static let preset = ToolDefinition(
        id: "13aabe41-172d-44ff-b8aa-58fa152dc0f9", formerID: "censys", name: "Censys", summary: "What an internet-facing host exposes: services, software, network and location.",
        defaultInstructions: """
        Use Censys to see what an IP address exposes to the internet: its services and ports, network and owner, \
        location and DNS names, as Censys last scanned it. Record each lookup as evidence. Lookups never scan anything.
        """,
        iconName: "censys",
        configuration: .connection(.init(endpoint: URL(string: "https://api.platform.censys.io/v3/global")!, tokenHeader: "Authorization",
                                  adapter: "censys")),
        setup: setup)

    static let setup = [
        "Sign in at [platform.censys.io](https://platform.censys.io), or create an account.",
        "In your account settings, open **Personal Access Tokens**, create a token and paste it here. Host lookups spend your account's credits.",
    ]

    public static let adapter = OperationAdapter(operations: [Host()])
}

extension Censys {
    struct Host: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String }
        static let name = "host"
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
