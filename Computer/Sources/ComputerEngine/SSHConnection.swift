import ComputerCore
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Security

/// What an SSH computer signs in with, besides asking for nothing first.
public enum SSHSecret: Equatable, Sendable {
    case key(SSHKey)
    case password(String)

    var credential: SSHDestination.Credential {
        switch self { case .key: .key; case .password: .password }
    }
}

/// A private key in a form the Keychain can keep and NIOSSH can sign with. RSA is not supported by NIOSSH.
public struct SSHKey: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case ed25519, p256, p384, p521 }
    let kind: Kind
    let raw: Data

    public static func generate() -> SSHKey { SSHKey(kind: .ed25519, raw: Curve25519.Signing.PrivateKey().rawRepresentation) }

    var privateKey: NIOSSHPrivateKey {
        get throws {
            switch kind {
            case .ed25519: NIOSSHPrivateKey(ed25519Key: try .init(rawRepresentation: raw))
            case .p256: NIOSSHPrivateKey(p256Key: try .init(rawRepresentation: raw))
            case .p384: NIOSSHPrivateKey(p384Key: try .init(rawRepresentation: raw))
            case .p521: NIOSSHPrivateKey(p521Key: try .init(rawRepresentation: raw))
            }
        }
    }

    /// The line to add to the server's `~/.ssh/authorized_keys`.
    public var publicLine: String {
        get throws { String(openSSHPublicKey: try privateKey.publicKey) + " noodle-computer" }
    }

    /// An unencrypted OpenSSH or PEM private key, as `ssh-keygen` writes it.
    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            self = try Self.openSSH(trimmed)
        } else if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
            self.init(kind: .p256, raw: key.rawRepresentation)
        } else if let key = try? P384.Signing.PrivateKey(pemRepresentation: trimmed) {
            self.init(kind: .p384, raw: key.rawRepresentation)
        } else if let key = try? P521.Signing.PrivateKey(pemRepresentation: trimmed) {
            self.init(kind: .p521, raw: key.rawRepresentation)
        } else if trimmed.contains("RSA PRIVATE KEY") {
            throw ComputerError("RSA keys are not supported. Use an Ed25519 or ECDSA key, or let Noodle Computer make one.")
        } else if trimmed.contains("ENCRYPTED") {
            throw ComputerError("Remove the key's passphrase first, with ssh-keygen -p, or let Noodle Computer make a key.")
        } else {
            throw ComputerError("This is not a private key Noodle Computer can read.")
        }
    }

    public init(kind: Kind, raw: Data) { self.kind = kind; self.raw = raw }

    private static func openSSH(_ text: String) throws -> SSHKey {
        let body = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-") }.joined()
        guard let data = Data(base64Encoded: body) else { throw ComputerError("This private key is damaged.") }
        var reader = SSHWireReader(data)
        guard reader.take(15) == Data("openssh-key-v1\0".utf8) else { throw ComputerError("This private key is damaged.") }
        let cipher = try reader.string()
        _ = try reader.string(); _ = try reader.string()
        guard String(decoding: cipher, as: UTF8.self) == "none" else {
            throw ComputerError("Remove the key's passphrase first, with ssh-keygen -p, or let Noodle Computer make a key.")
        }
        guard try reader.uint32() == 1 else { throw ComputerError("Use a file with a single private key.") }
        _ = try reader.string()
        var section = SSHWireReader(try reader.string())
        guard try section.uint32() == section.uint32() else { throw ComputerError("This private key is damaged.") }
        let type = String(decoding: try section.string(), as: UTF8.self)
        func scalar(_ size: Int) throws -> Data {
            // An mpint carries a sign byte when its top bit is set, and drops leading zeros.
            var value = try section.string()
            while value.count > size, value.first == 0 { value.removeFirst() }
            guard value.count <= size else { throw ComputerError("This private key is damaged.") }
            return Data(repeating: 0, count: size - value.count) + value
        }
        switch type {
        case "ssh-ed25519":
            _ = try section.string()
            let secret = try section.string()
            guard secret.count == 64 else { throw ComputerError("This private key is damaged.") }
            return SSHKey(kind: .ed25519, raw: secret.prefix(32))
        case "ecdsa-sha2-nistp256": _ = try section.string(); _ = try section.string(); return SSHKey(kind: .p256, raw: try scalar(32))
        case "ecdsa-sha2-nistp384": _ = try section.string(); _ = try section.string(); return SSHKey(kind: .p384, raw: try scalar(48))
        case "ecdsa-sha2-nistp521": _ = try section.string(); _ = try section.string(); return SSHKey(kind: .p521, raw: try scalar(66))
        case "ssh-rsa": throw ComputerError("RSA keys are not supported. Use an Ed25519 or ECDSA key, or let Noodle Computer make one.")
        default: throw ComputerError("This kind of key (\(type)) is not supported.")
        }
    }
}

struct SSHWireReader {
    private var data: Data
    init(_ data: Data) { self.data = Data(data) }
    var isAtEnd: Bool { data.isEmpty }
    mutating func take(_ count: Int) -> Data? {
        guard data.count >= count else { return nil }
        defer { data = Data(data.dropFirst(count)) }
        return Data(data.prefix(count))
    }
    mutating func uint32() throws -> UInt32 {
        guard let bytes = take(4) else { throw ComputerError("The server sent a damaged reply.") }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
    mutating func uint64() throws -> UInt64 {
        guard let bytes = take(8) else { throw ComputerError("The server sent a damaged reply.") }
        return bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
    mutating func byte() throws -> UInt8 {
        guard let bytes = take(1) else { throw ComputerError("The server sent a damaged reply.") }
        return bytes[bytes.startIndex]
    }
    mutating func string() throws -> Data {
        let count = Int(try uint32())
        guard let bytes = take(count) else { throw ComputerError("The server sent a damaged reply.") }
        return bytes
    }
}

/// The key or password for each SSH computer, in this app's Keychain.
public struct SSHSecretStore: Sendable {
    var save: @Sendable (SSHSecret, UUID) throws -> Void
    var load: @Sendable (UUID) throws -> SSHSecret?
    var delete: @Sendable (UUID) -> Void

    private struct Stored: Codable { var kind: String; var data: Data }
    private static let service = "Noodle Computer SSH"

    public static let keychain = SSHSecretStore(save: { secret, id in
        let stored: Stored
        switch secret {
        case .key(let key): stored = Stored(kind: key.kind.rawValue, data: key.raw)
        case .password(let password): stored = Stored(kind: "password", data: Data(password.utf8))
        }
        let data = try JSONEncoder().encode(stored)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Noodle Computer SSH sign-in"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ComputerError("The Keychain did not keep the sign-in (\(status)).") }
    }, load: { id in
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ComputerError("The Keychain did not return the sign-in (\(status)).") }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        if stored.kind == "password" { return .password(String(decoding: stored.data, as: UTF8.self)) }
        guard let kind = SSHKey.Kind(rawValue: stored.kind) else { throw ComputerError("The Keychain holds an unknown sign-in.") }
        return .key(SSHKey(kind: kind, raw: stored.data))
    }, delete: { id in
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    })
}

struct SSHHostKeyChanged: LocalizedError {
    var errorDescription: String? {
        "The server's key has changed since it was added, so Noodle Computer did not sign in. If you expect this, such as after reinstalling the server, choose Forget Server Key in Edit Computer."
    }
}

/// One signed-in SSH connection. Shells, files and commands each open their own channel on it.
final class SSHConnection: @unchecked Sendable {
    let channel: Channel
    /// The server's key in OpenSSH form, as it answered this time.
    let hostKey: String

    private init(channel: Channel, hostKey: String) { self.channel = channel; self.hostKey = hostKey }

    /// Asks for nothing first, as Tailscale SSH and other network-trusting servers expect, then the secret if there is one.
    static func connect(to destination: SSHDestination, secret: SSHSecret?, timeout: TimeAmount = .seconds(120),
                        notice: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SSHConnection {
        let signIn = SSHSignIn(user: destination.user, secret: secret)
        let hostKeys = SSHHostKeyCheck(expected: destination.hostKey)
        let ready = SSHReadyHandler(notice: notice)
        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: signIn, serverAuthDelegate: hostKeys)),
                                            allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers(ssh, ready)
                    // A refused sign-in ends here, rather than waiting for the deadline.
                    signIn.refused = { [weak channel] message in
                        if let channel { ready.fail(ComputerError(message), channel: channel) }
                    }
                }
            }
        let channel: Channel
        do { channel = try await bootstrap.connect(host: destination.host, port: destination.port).get() }
        catch { throw ComputerError("Could not reach \(destination.host): \(SSHConnection.describe(error))") }
        let deadline = channel.eventLoop.scheduleTask(in: timeout) {
            ready.fail(ComputerError("\(destination.host) did not finish signing in."), channel: channel)
        }
        defer { deadline.cancel() }
        do {
            try await ready.signedIn.futureResult.get()
        } catch {
            try? await channel.close()
            if hostKeys.changed { throw SSHHostKeyChanged() }
            if let refused = signIn.refusal { throw ComputerError(refused) }
            throw error
        }
        guard let presented = hostKeys.presented else { throw ComputerError("The server did not identify itself.") }
        return SSHConnection(channel: channel, hostKey: presented)
    }

    var closed: EventLoopFuture<Void> { channel.closeFuture }
    func close() { channel.close(promise: nil) }

    /// A session channel with `handler` at the end of its pipeline.
    func openSession(_ handler: @escaping @Sendable () -> ChannelHandler) async throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute { [channel] in
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .session) { child, type in
                    guard type == .session else { return child.eventLoop.makeFailedFuture(ComputerError("The server opened the wrong kind of channel.")) }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(handler())
                    }.flatMap { child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) }
                }
            } catch { promise.fail(error) }
        }
        do { return try await promise.futureResult.get() }
        catch { throw ComputerError("The server did not open a session: \(Self.describe(error))") }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        if let error = error as? NIOConnectionError {
            return error.connectionErrors.first.map { describe($0.error) } ?? "the connection failed."
        }
        if let error = error as? IOError { return String(cString: strerror(error.errnoCode)) + "." }
        if error is ChannelError { return "the connection closed." }
        return String(describing: error)
    }
}

private final class SSHSignIn: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private let secret: SSHSecret?
    private var askedForNothing = false
    private var offeredSecret = false
    private(set) var refusal: String?
    var refused: ((String) -> Void)?

    init(user: String, secret: SSHSecret?) { self.user = user; self.secret = secret }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if !askedForNothing {
            askedForNothing = true
            nextChallengePromise.succeed(.init(username: user, serviceName: "ssh-connection", offer: .none))
            return
        }
        if !offeredSecret, let secret {
            offeredSecret = true
            switch secret {
            case .key(let key) where availableMethods.contains(.publicKey):
                if let privateKey = try? key.privateKey {
                    nextChallengePromise.succeed(.init(username: user, serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: privateKey))))
                    return
                }
            case .password(let password) where availableMethods.contains(.password):
                nextChallengePromise.succeed(.init(username: user, serviceName: "ssh-connection", offer: .password(.init(password: password))))
                return
            default: break
            }
        }
        switch secret {
        case .key: refusal = offeredSecret ? "The server did not accept the key for \(user). Add its public key to ~/.ssh/authorized_keys on the server." : "The server does not accept keys for \(user)."
        case .password: refusal = offeredSecret ? "The server did not accept the password for \(user)." : "The server does not accept passwords for \(user)."
        case nil: refusal = "The server needs a key or password for \(user)."
        }
        nextChallengePromise.succeed(nil)
        if let refusal { refused?(refusal) }
    }
}

private final class SSHHostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expected: String?
    private(set) var presented: String?
    private(set) var changed = false
    init(expected: String?) { self.expected = expected }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        presented = key
        if let expected, Self.normalized(expected) != Self.normalized(key) {
            changed = true
            validationCompletePromise.fail(SSHHostKeyChanged())
        } else {
            validationCompletePromise.succeed(())
        }
    }

    /// The type and key, without any comment.
    static func normalized(_ key: String) -> String { key.split(separator: " ").prefix(2).joined(separator: " ") }
}

/// Settles once the server lets the client in, and passes on what the server asks to show the person.
private final class SSHReadyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let notice: @Sendable (String) -> Void
    private var promise: EventLoopPromise<Void>?
    var signedIn: EventLoopPromise<Void> { promise! }

    init(notice: @escaping @Sendable (String) -> Void) { self.notice = notice }

    func handlerAdded(context: ChannelHandlerContext) { promise = context.eventLoop.makePromise() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { promise?.succeed(()) }
        else if let banner = event as? NIOUserAuthBannerEvent {
            let text = banner.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { notice(String(text.prefix(2000))) }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise?.fail(ComputerError(SSHConnection.describe(error)))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise?.fail(ComputerError("The server closed the connection."))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        promise?.fail(ComputerError("The connection closed."))
    }

    func fail(_ error: Error, channel: Channel) {
        promise?.fail(error)
        channel.close(promise: nil)
    }
}

/// An interactive login shell on a pseudo-terminal.
final class SSHShell: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Never
    private let columns: Int, rows: Int
    private let output: @Sendable (Data) -> Void
    private let exited: @Sendable () -> Void
    private var context: ChannelHandlerContext?

    init(columns: Int, rows: Int, output: @escaping @Sendable (Data) -> Void, exited: @escaping @Sendable () -> Void) {
        self.columns = max(columns, 20); self.rows = max(rows, 5); self.output = output; self.exited = exited
    }

    static func open(on connection: SSHConnection, columns: Int, rows: Int,
                     output: @escaping @Sendable (Data) -> Void, exited: @escaping @Sendable () -> Void) async throws -> Channel {
        let channel = try await connection.openSession { SSHShell(columns: columns, rows: rows, output: output, exited: exited) }
        let terminal = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: max(columns, 20), terminalRowHeight: max(rows, 5), terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        do {
            try await channel.triggerUserOutboundEvent(terminal).get()
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).get()
        } catch {
            try? await channel.close()
            throw ComputerError("The server did not start a shell.")
        }
        return channel
    }

    static func write(_ data: Data, to channel: Channel) {
        guard !data.isEmpty else { return }
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data))), promise: nil)
    }

    static func resize(_ channel: Channel, columns: Int, rows: Int) {
        let change = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: max(columns, 20), terminalRowHeight: max(rows, 5),
                                                               terminalPixelWidth: 0, terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(change, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = message.data, let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        output(Data(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // The shell ending closes its input too, so the channel ends with it.
        if event is ChannelEvent, case .inputClosed = event as! ChannelEvent { context.close(promise: nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        exited()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
