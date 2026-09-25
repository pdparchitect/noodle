import CryptoKit
import Foundation

public enum LinkRequest: Codable, Equatable, Sendable {
    /// Pairs the key this request arrives with to the invitation's user. The token works once.
    case enroll(token: String, deviceName: String)
    /// What the Hub lends this device's user.
    case status
}

public enum LinkResponse: Codable, Equatable, Sendable {
    case status(LinkStatus)
    case failure(String)
}

public struct LinkStatus: Codable, Equatable, Sendable {
    public var hubName: String
    public var userName: String
    public var planName: String
    public var harnesses: [LinkHarness]
    /// The Hub's current addresses, so a device keeps up when they change.
    public var endpoints: [LinkEndpoint]

    public init(hubName: String, userName: String, planName: String, harnesses: [LinkHarness], endpoints: [LinkEndpoint]) {
        self.hubName = hubName
        self.userName = userName
        self.planName = planName
        self.harnesses = harnesses
        self.endpoints = endpoints
    }
}

/// A harness login the Hub lends. `profileName` is nil for the harness's own login.
public struct LinkHarness: Codable, Hashable, Sendable {
    public var provider: String
    public var providerName: String
    public var profileName: String?

    public init(provider: String, providerName: String, profileName: String?) {
        self.provider = provider
        self.providerName = providerName
        self.profileName = profileName
    }
}

/// Everything a device needs to find a Hub, trust it and pair once.
public struct LinkInvitation: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 15 * 60
    public static let urlHost = "join-hub"

    public var hubName: String
    public var hubKey: LinkPublicKey
    public var endpoints: [LinkEndpoint]
    public var userName: String
    public var token: String
    public var expires: Date

    public init(hubName: String, hubKey: LinkPublicKey, endpoints: [LinkEndpoint], userName: String, token: String, expires: Date) {
        self.hubName = hubName
        self.hubKey = hubKey
        self.endpoints = endpoints
        self.userName = userName
        self.token = token
        self.expires = expires
    }

    public static func newToken() -> String {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }).base64URL
    }

    /// What the Hub keeps instead of the token itself.
    public static func tokenDigest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    /// A link Noodle opens, which is also what the QR code holds.
    public func url(scheme: String = "noodle") -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = Self.urlHost
        components.queryItems = [URLQueryItem(name: "i", value: encoded)]
        return components.url!
    }

    /// Reads a link from any Noodle build, or the bare code inside it.
    public init(text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = URLComponents(string: text).flatMap { components in
            components.host == Self.urlHost ? components.queryItems?.first { $0.name == "i" }?.value : nil
        } ?? text
        guard let data = Data(base64URL: code), let invitation = try? Self.decoder.decode(Self.self, from: data) else {
            throw LinkError("This is not a Noodle Hub invitation.")
        }
        self = invitation
    }

    private var encoded: String { (try! Self.encoder.encode(self)).base64URL }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
