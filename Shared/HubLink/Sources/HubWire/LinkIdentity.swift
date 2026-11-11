#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A Hub's or device's long-lived key. The public key is who it is; TLS proves
/// the other side holds the private half. The certificate only carries the key.
public struct LinkIdentity: Sendable {
    public let privateKey: P256.Signing.PrivateKey
    public var publicKey: LinkPublicKey { LinkPublicKey(privateKey.publicKey) }

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    /// Reads the key saved at `url`, or makes and saves one readable only by this user.
    public static func loadOrCreate(at url: URL) throws -> LinkIdentity {
        if let data = try? Data(contentsOf: url) {
            return LinkIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: data))
        }
        let identity = LinkIdentity()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: identity.privateKey.rawRepresentation,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw LinkError("Could not save the link key.")
        }
        // Another process may have saved one first; keep whichever landed.
        if (try? FileManager.default.moveItem(at: temporary, to: url)) == nil {
            try? FileManager.default.removeItem(at: temporary)
            return LinkIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: try Data(contentsOf: url)))
        }
        return identity
    }

    /// Signs the invitation's key, proving to the Hub that this side holds the key it asks to pair.
    public func joinProof(for invitationKey: LinkPublicKey) throws -> Data {
        try privateKey.signature(for: LinkPublicKey.joinProofMessage(invitationKey)).rawRepresentation
    }
}

/// Who a peer is: its P-256 public key, compared byte for byte.
public struct LinkPublicKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let x963: Data

    public init(_ key: P256.Signing.PublicKey) { x963 = key.x963Representation }

    public init(x963: Data) throws {
        _ = try P256.Signing.PublicKey(x963Representation: x963)
        self.x963 = x963
    }

    /// Whether `proof` shows the holder of this key asked to pair through the invitation with `invitationKey`.
    public func isJoinProof(_ proof: Data, for invitationKey: LinkPublicKey) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: x963),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: proof) else { return false }
        return key.isValidSignature(signature, for: Self.joinProofMessage(invitationKey))
    }

    fileprivate static func joinProofMessage(_ invitationKey: LinkPublicKey) -> Data {
        Data("noodle-hub-join".utf8) + invitationKey.x963
    }

    /// Short and stable, for showing a person which key they are trusting.
    public var fingerprint: String {
        SHA256.hash(data: x963).prefix(8).map { String(format: "%02X", $0) }
            .chunked(2).map { $0.joined() }.joined(separator: " ")
    }

    public var description: String { fingerprint }

    public init(from decoder: Decoder) throws {
        try self.init(x963: try decoder.singleValueContainer().decode(Data.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(x963)
    }
}

public struct LinkError: LocalizedError, Equatable, Sendable {
    public let message: String
    /// No address of the Hub answered, as opposed to the Hub answering with a refusal.
    public let isUnreachable: Bool
    public init(_ message: String, isUnreachable: Bool = false) {
        self.message = message
        self.isUnreachable = isUnreachable
    }
    public var errorDescription: String? { message }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
