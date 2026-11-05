import ComputerBridge
import ComputerCore
import CryptoKit
import Darwin
import NIOCore
import NIOPosix
import NIOSSH
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

/// Against an SSH server in this process on the loopback address, with SFTP served from a temporary folder.
@MainActor final class SSHComputerTests: XCTestCase {
    private var server: TestSSHServer!
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? await server?.channel.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func start(_ accepts: TestSSHServer.Accepts, banner: String? = nil) async throws -> SSHDestination {
        server = try await TestSSHServer.start(accepts: accepts, root: root, banner: banner)
        return SSHDestination(host: "127.0.0.1", port: server.port, user: "me")
    }

    func testServersThatTrustTheNetworkNeedNoKeyAndShowTheirMessage() async throws {
        let destination = try await start(.anyone, banner: "Visit https://login.tailscale.com/a/check to continue")
        let notices = Notices()
        let connection = try await SSHConnection.connect(to: destination, secret: nil) { notices.append($0) }
        defer { connection.close() }
        XCTAssertEqual(SSHHostKeyCheckTests.normalized(connection.hostKey), SSHHostKeyCheckTests.normalized(server.hostKeyLine))
        XCTAssertEqual(notices.all, ["Visit https://login.tailscale.com/a/check to continue"])
        XCTAssertEqual(ComputerNotice.linked(notices.all[0]).runs.compactMap(\.link), [URL(string: "https://login.tailscale.com/a/check")!])
    }

    func testAKeyIsOfferedWhenTheServerWantsOne() async throws {
        let key = SSHKey.generate()
        let destination = try await start(.key(try key.privateKey.publicKey))
        let connection = try await SSHConnection.connect(to: destination, secret: .key(key))
        connection.close()
        await assertRefused(destination, secret: nil, "The server needs a key or password for me.")
        await assertRefused(destination, secret: .key(.generate()), "The server did not accept the key for me. Add its public key to ~/.ssh/authorized_keys on the server.")
        await assertRefused(destination, secret: .password("x"), "The server did not accept the password for me.")
    }

    func testAPasswordIsOfferedWhenTheServerWantsOne() async throws {
        let destination = try await start(.password("open sesame"))
        let connection = try await SSHConnection.connect(to: destination, secret: .password("open sesame"))
        connection.close()
        await assertRefused(destination, secret: .password("wrong"), "The server did not accept the password for me.")
    }

    func testAServerWhoseKeyChangedIsRefused() async throws {
        var destination = try await start(.anyone)
        destination.hostKey = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey)
        do {
            _ = try await SSHConnection.connect(to: destination, secret: nil)
            XCTFail("Signed in to a server with a different key")
        } catch { XCTAssertTrue(error is SSHHostKeyChanged, "\(error)") }
        // The trusted key, with or without its comment, signs in.
        destination.hostKey = server.hostKeyLine + " server"
        try await SSHConnection.connect(to: destination, secret: nil).close()
    }

    func testAnUnreachableServerSaysSo() async throws {
        let destination = SSHDestination(host: "127.0.0.1", port: 1, user: "me")
        do {
            _ = try await SSHConnection.connect(to: destination, secret: nil)
            XCTFail("Connected to a closed port")
        } catch { XCTAssertTrue(error.localizedDescription.hasPrefix("Could not reach 127.0.0.1"), error.localizedDescription) }
    }

    func testAShellCarriesInputAndOutput() async throws {
        let connection = try await SSHConnection.connect(to: try await start(.anyone), secret: nil)
        defer { connection.close() }
        let output = Notices()
        let exited = expectation(description: "exited")
        let channel = try await SSHShell.open(on: connection, columns: 100, rows: 40, output: {
            output.append(String(decoding: $0, as: UTF8.self))
        }, exited: { exited.fulfill() })
        SSHShell.write(Data("hello\n".utf8), to: channel)
        try await waitUntil { output.all.joined().contains("hello\n") }
        XCTAssertEqual(server.terminalSize, "100x40")
        SSHShell.resize(channel, columns: 132, rows: 50)
        try await waitUntil { self.server.terminalSize == "132x50" }
        SSHShell.write(Data("exit\n".utf8), to: channel)
        await fulfillment(of: [exited], timeout: 5)
    }

    func testReturnOpensANewShellAfterTheShellExits() async throws {
        let connection = try await SSHConnection.connect(to: try await start(.anyone), secret: nil)
        defer { connection.close() }
        let terminal = GuestTerminal()
        let shell = SSHTerminalConnection(connection: connection, terminal: terminal)
        try await shell.start()
        try await waitUntil { self.server.shells == 1 }
        terminal.send(source: terminal.view, data: Array("exit\n".utf8)[...])
        try await waitUntil { shell.ended && terminal.retryConnection != nil }
        terminal.send(source: terminal.view, data: [13][...])
        try await waitUntil { self.server.shells == 2 && !shell.ended }
        XCTAssertNil(terminal.retryConnection)
        shell.close()
    }

    func testFilesWorkOverSFTP() async throws {
        let connection = try await SSHConnection.connect(to: try await start(.anyone), secret: nil)
        defer { connection.close() }
        let files = SSHFileService(connection: connection)
        let home = try await files.homeDirectory()
        XCTAssertEqual(home, "/")
        try await files.change("mkdir", path: "/docs")
        let source = root.appendingPathComponent("../ssh-source-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: source) }
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        try content.write(to: source)
        try await files.upload(source, to: "/docs/a.bin", progress: { _ in })
        let listing = try await files.list("/docs")
        XCTAssertEqual(listing.map(\.name), ["a.bin"], "The hidden staging file is gone")
        XCTAssertEqual(listing.first?.size, 200_000)
        XCTAssertEqual(listing.first?.kind, "file")
        let top = try await files.list("/")
        XCTAssertEqual(top.map(\.name), ["docs"])
        XCTAssertEqual(top.first?.directory, true)

        let back = root.appendingPathComponent("../ssh-back-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: back) }
        let downloaded = try await files.download("/docs/a.bin", to: back)
        XCTAssertEqual(downloaded, 200_000)
        XCTAssertEqual(try Data(contentsOf: back), content)

        // An upload never replaces an existing file.
        do {
            try await files.upload(source, to: "/docs/a.bin", progress: { _ in })
            XCTFail("Replaced an existing file")
        } catch { XCTAssertEqual(error.localizedDescription, "An item with that name already exists.") }
        let unchanged = try await files.list("/docs")
        XCTAssertEqual(unchanged.map(\.name), ["a.bin"])

        let file = try XCTUnwrap(listing.first)
        try await files.change("copy", path: "/docs/a.bin", extra: [file.version, "/docs/b.bin"])
        try await files.change("rename", path: "/docs/b.bin", extra: ["/c.bin"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("c.bin")), content)
        do {
            try await files.change("copy", path: "/docs/a.bin", extra: ["0:0", "/d.bin"])
            XCTFail("Copied a file that changed")
        } catch { XCTAssertEqual(error.localizedDescription, "The file changed; refresh and try again.") }
        do {
            try await files.change("remove", path: "/docs")
            XCTFail("Removed a folder that is not empty")
        } catch {}
        try await files.change("remove", path: "/docs/a.bin")
        try await files.change("remove", path: "/docs")
        let remaining = try await files.list("/")
        XCTAssertEqual(remaining.map(\.name), ["c.bin"])
    }

    func testAnSSHComputerIsCreatedStartedAndStopped() async throws {
        let key = SSHKey.generate()
        let destination = try await start(.key(try key.privateKey.publicKey))
        let secrets = MemorySecrets()
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let store = try ComputerStore(root: library, sshSecrets: secrets.store)
        var computer = Computer(name: "Server", kind: .ssh)
        computer.ssh = destination

        // A refused sign-in leaves nothing behind.
        let refused = await store.create(computer, source: nil, sshSecret: .password("nope"))
        XCTAssertFalse(refused)
        XCTAssertEqual(store.error, "The server did not accept the password for me.")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(secrets.saved.isEmpty)

        let created = await store.create(computer, source: nil, sshSecret: .key(key))
        XCTAssertTrue(created, store.error ?? "")
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.computer.ssh?.hostKey, server.hostKeyLine)
        XCTAssertEqual(session.computer.ssh?.credential, .key)
        XCTAssertEqual(secrets.saved[computer.id], .key(key))
        XCTAssertEqual(session.availableDisplayModes, [.terminal, .files])

        await store.start(session)
        XCTAssertEqual(session.phase, .running)
        XCTAssertNotNil(session.terminal)
        XCTAssertEqual(session.displayMode, .terminal)
        await store.selectDisplay(.files, in: session)
        XCTAssertEqual(session.displayMode, .files)
        XCTAssertFalse(session.canDelete)

        await store.stop(session)
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertNil(session.sshRuntime)
        XCTAssertNil(session.terminal)
        XCTAssertTrue(session.canDelete)
    }

    func testTheSignInCanBeChangedAndIsCheckedFirst() async throws {
        let destination = try await start(.password("first"))
        let secrets = MemorySecrets()
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let store = try ComputerStore(root: library, sshSecrets: secrets.store)
        var computer = Computer(name: "Server", kind: .ssh)
        computer.ssh = destination
        let created = await store.create(computer, source: nil, sshSecret: .password("first"))
        XCTAssertTrue(created, store.error ?? "")
        let session = try XCTUnwrap(store.sessions.first)

        // A sign-in the server refuses changes nothing.
        do {
            try await store.changeSignIn(session, to: destination, secret: .password("wrong"))
            XCTFail("Saved a refused sign-in")
        } catch { XCTAssertEqual(error.localizedDescription, "The server did not accept the password for me.") }
        XCTAssertEqual(secrets.saved[computer.id], .password("first"))

        // Keeping the saved secret while changing nothing else still works.
        try await store.changeSignIn(session, to: destination, secret: nil, keepSaved: true)
        XCTAssertEqual(secrets.saved[computer.id], .password("first"))
        XCTAssertEqual(session.computer.ssh?.credential, .password)

        // The same server on a new address is trusted again, with a new sign-in.
        try? await server.channel.close()
        let moved = try await start(.anyone)
        try await store.changeSignIn(session, to: moved, secret: nil)
        XCTAssertNil(secrets.saved[computer.id])
        XCTAssertEqual(session.computer.ssh?.port, moved.port)
        XCTAssertNil(session.computer.ssh?.credential)
        XCTAssertEqual(session.computer.ssh?.hostKey, server.hostKeyLine)
        XCTAssertEqual(try store.library.load().first?.ssh, session.computer.ssh)
        await store.start(session)
        XCTAssertEqual(session.phase, .running)
        await store.stop(session)
    }

    func testBotsUseAnSSHComputerThroughTheProvider() async throws {
        let destination = try await start(.anyone)
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library) }
        let store = try ComputerStore(root: library, sshSecrets: MemorySecrets().store)
        var computer = Computer(name: "Server", kind: .ssh)
        computer.ssh = destination
        let created = await store.create(computer, source: nil)
        XCTAssertTrue(created, store.error ?? "")
        let provider = try ComputerProvider(store: store, socket: library.appendingPathComponent("p.sock"), listens: false)
        let peer = "com.pdparchitect.noodle.integration"
        var list = ComputerRequest(.list)
        list.agentID = UUID()
        let listed = try await provider.handle(list, peer: peer)
        XCTAssertEqual(listed.computers?.map(\.id), [computer.id])

        var start = ComputerRequest(.start); start.computerID = computer.id; start.agentID = list.agentID
        _ = try await provider.handle(start, peer: peer)
        var open = start; open.operation = .terminalOpen
        let opened = try await provider.handle(open, peer: peer)
        let terminal = try XCTUnwrap(opened.terminalID)
        var write = open; write.operation = .terminalWrite; write.terminalID = terminal; write.data = Data("from the bot\n".utf8)
        _ = try await provider.handle(write, peer: peer)
        var read = write; read.operation = .terminalRead; read.data = nil; read.offset = 0
        try await waitUntil {
            let reply = try await provider.handle(read, peer: peer)
            return String(decoding: reply.data ?? Data(), as: UTF8.self).contains("from the bot")
        }
        // Another agent cannot use it.
        var other = read; other.agentID = UUID()
        do { _ = try await provider.handle(other, peer: peer); XCTFail("Another agent read the terminal") } catch {}

        // The bot finds its shell again. A server cannot say whether a command runs in it, so an
        // unused shell is kept six hours rather than half of one.
        var clock = Date()
        provider.now = { clock }
        var mine = open; mine.operation = .terminalList
        let found = try await provider.handle(mine, peer: peer).terminals ?? []
        XCTAssertEqual(found.map(\.id), [terminal])
        XCTAssertNil(found.first?.running)
        XCTAssertEqual(found.first?.exited, false)
        var others = mine; others.agentID = UUID()
        let theirs = try await provider.handle(others, peer: peer).terminals ?? []
        XCTAssertEqual(theirs, [], "each bot lists its own")
        clock += 31 * 60
        let secondReply = try await provider.handle(open, peer: peer)
        let second = try XCTUnwrap(secondReply.terminalID)
        let kept = try await provider.handle(mine, peer: peer).terminals ?? []
        XCTAssertEqual(kept.map(\.id), [terminal, second])
        clock += 6 * 60 * 60
        let thirdReply = try await provider.handle(open, peer: peer)
        let third = try XCTUnwrap(thirdReply.terminalID)
        let left = try await provider.handle(mine, peer: peer).terminals ?? []
        XCTAssertEqual(left.map(\.id), [third])
    }

    func testKeysAreReadAsSSHKeygenWritesThem() throws {
        let ed25519 = try SSHKey(text: """
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
            QyNTUxOQAAACCsiIALN/jiA0smMidldfz8MO6Rll55BjuuZj8ZUKzm0AAAAIitGUt8rRlL
            fAAAAAtzc2gtZWQyNTUxOQAAACCsiIALN/jiA0smMidldfz8MO6Rll55BjuuZj8ZUKzm0A
            AAAEAa2m6LoksLAZnnZOFlJeYV7EFtRAqDBZH+/rvIsvaPvKyIgAs3+OIDSyYyJ2V1/Pww
            7pGWXnkGO65mPxlQrObQAAAABHRlc3QB
            -----END OPENSSH PRIVATE KEY-----
            """)
        XCTAssertEqual(try ed25519.publicLine, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKyIgAs3+OIDSyYyJ2V1/Pww7pGWXnkGO65mPxlQrObQ noodle-computer")
        let ecdsa = try SSHKey(text: """
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
            1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQTuNn2XGiyeb70XwjVo2g2AwELSiNbV
            wRd9ubkCkSJZVOP51Y3U5IJa4oxrfgYDWrymJKQKZzSiwqZeCypHNhJ7AAAAoKOPBYGjjw
            WBAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBO42fZcaLJ5vvRfC
            NWjaDYDAQtKI1tXBF325uQKRIllU4/nVjdTkglrijGt+BgNavKYkpApnNKLCpl4LKkc2En
            sAAAAgQQfo759sUWLTPTBdSaF/vIQ/kaMoh19i5Q7kBY1goUQAAAAEdGVzdAECAwQ=
            -----END OPENSSH PRIVATE KEY-----
            """)
        XCTAssertEqual(try ecdsa.publicLine, "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBO42fZcaLJ5vvRfCNWjaDYDAQtKI1tXBF325uQKRIllU4/nVjdTkglrijGt+BgNavKYkpApnNKLCpl4LKkc2Ens= noodle-computer")
        let pem = P256.Signing.PrivateKey()
        XCTAssertEqual(try SSHKey(text: pem.pemRepresentation), SSHKey(kind: .p256, raw: pem.rawRepresentation))
        XCTAssertThrowsError(try SSHKey(text: """
            -----BEGIN OPENSSH PRIVATE KEY-----
            b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCRdEdiZQ
            Uw87iFMMU3GhReAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFIJyWyc1g6CvOWX
            +cmD2IcP7e/hj1+k7XG13KEooasRAAAAkB4HAnwg6LApeTg1W+pBkFO/EwFQ7BQQDFJ4Ux
            aJgMaQcrqbjlQW/qOTTo7ioprr3FPt34wWYtrJdlwFtarIviEwZI1+pmDnLSazOPq3tFGd
            S203e8JO6ddaV3jHJ3WpbSw7w1zGi2xOuK35jSc5vMrNJMMbHpVXJ3OEtLzhiFQPvwXp85
            SZ/2qYxztYoZ4kBA==
            -----END OPENSSH PRIVATE KEY-----
            """)) { XCTAssertTrue($0.localizedDescription.contains("passphrase"), $0.localizedDescription) }
        XCTAssertThrowsError(try SSHKey(text: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----")) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("RSA keys are not supported"))
        }
        XCTAssertThrowsError(try SSHKey(text: "hello"))
    }

    private func assertRefused(_ destination: SSHDestination, secret: SSHSecret?, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let connection = try await SSHConnection.connect(to: destination, secret: secret)
            connection.close()
            XCTFail("Signed in", file: file, line: line)
        } catch { XCTAssertEqual(error.localizedDescription, message, file: file, line: line) }
    }

    private func waitUntil(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out")
    }
}

enum SSHHostKeyCheckTests {
    static func normalized(_ key: String) -> String { key.split(separator: " ").prefix(2).joined(separator: " ") }
}

private final class Notices: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private final class MemorySecrets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: SSHSecret] = [:]
    var saved: [UUID: SSHSecret] { lock.withLock { values } }
    var store: SSHSecretStore {
        SSHSecretStore(save: { secret, id in self.lock.withLock { self.values[id] = secret } },
                       load: { id in self.lock.withLock { self.values[id] } },
                       delete: { id in _ = self.lock.withLock { self.values.removeValue(forKey: id) } })
    }
}

/// Enough of an SSH server for the client: sign-in, an echoing shell and SFTP over a folder.
final class TestSSHServer: @unchecked Sendable {
    enum Accepts { case anyone, key(NIOSSHPublicKey), password(String) }
    let channel: Channel
    let hostKeyLine: String
    var port: Int { channel.localAddress!.port! }
    private let lock = NSLock()
    private var size = ""
    private var shellCount = 0
    var terminalSize: String { lock.withLock { size } }
    var shells: Int { lock.withLock { shellCount } }

    private init(channel: Channel, hostKeyLine: String) { self.channel = channel; self.hostKeyLine = hostKeyLine }

    static func start(accepts: Accepts, root: URL, banner: String?) async throws -> TestSSHServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let box = Box()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: Auth(accepts: accepts),
                        banner: banner.map { .init(message: $0, languageTag: "en") })
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .server(configuration), allocator: channel.allocator) { child, _ in
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(Session(root: root, server: box))
                        }.flatMap { child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) }
                    })
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let server = TestSSHServer(channel: channel, hostKeyLine: String(openSSHPublicKey: hostKey.publicKey))
        box.server = server
        return server
    }

    final class Box: @unchecked Sendable { weak var server: TestSSHServer? }

    private final class Auth: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let accepts: Accepts
        init(accepts: Accepts) { self.accepts = accepts }
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
            switch accepts { case .anyone: .all; case .key: .publicKey; case .password: .password }
        }
        func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            switch (accepts, request.request) {
            case (.anyone, _): responsePromise.succeed(.success)
            case (.key(let expected), .publicKey(let offered)) where offered.publicKey == expected: responsePromise.succeed(.success)
            case (.password(let expected), .password(let offered)) where offered.password == expected: responsePromise.succeed(.success)
            default: responsePromise.succeed(.failure)
            }
        }
    }

    /// A shell that echoes each line and ends on `exit`, or SFTP when asked for it.
    private final class Session: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = SSHChannelData
        let root: URL
        let server: Box
        var sftp: TestSFTPServer?
        init(root: URL, server: Box) { self.root = root; self.server = server }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            switch event {
            case let terminal as SSHChannelRequestEvent.PseudoTerminalRequest:
                server.server?.lock.withLock { server.server?.size = "\(terminal.terminalCharacterWidth)x\(terminal.terminalRowHeight)" }
                if terminal.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            case let change as SSHChannelRequestEvent.WindowChangeRequest:
                server.server?.lock.withLock { server.server?.size = "\(change.terminalCharacterWidth)x\(change.terminalRowHeight)" }
            case let shell as SSHChannelRequestEvent.ShellRequest:
                server.server?.lock.withLock { server.server?.shellCount += 1 }
                if shell.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            case let subsystem as SSHChannelRequestEvent.SubsystemRequest where subsystem.subsystem == "sftp":
                sftp = TestSFTPServer(root: root)
                if subsystem.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            default: context.fireUserInboundEventTriggered(event)
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .byteBuffer(var buffer) = unwrapInboundIn(data).data, let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            if let sftp {
                for reply in sftp.receive(Data(bytes)) {
                    context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: reply)))), promise: nil)
                }
                return
            }
            context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))), promise: nil)
            if String(decoding: bytes, as: UTF8.self).contains("exit\n") { context.close(promise: nil) }
        }
    }
}

/// SFTP 3 over a folder, as OpenSSH answers: renames never replace, removes are not recursive.
final class TestSFTPServer {
    private let root: URL
    private var buffer = Data()
    private var handles: [Data: Int32] = [:]
    private var directories: [Data: (folder: String, names: [String])] = [:]
    private var next = 0

    init(root: URL) { self.root = root }

    private func local(_ path: String) -> String {
        let relative = path == "." ? "" : path
        return root.appendingPathComponent(relative).standardizedFileURL.path
    }

    func receive(_ data: Data) -> [Data] {
        buffer.append(data)
        var replies: [Data] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard buffer.count >= 4 + length else { break }
            var reader = SSHWireReader(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
            if let reply = try? handle(&reader) {
                var packet = Data(); packet.append(uint32: UInt32(reply.count)); packet.append(reply)
                replies.append(packet)
            }
        }
        return replies
    }

    private func status(_ id: UInt32, _ code: UInt32, _ message: String = "") -> Data {
        var body = Data([101]); body.append(uint32: id); body.append(uint32: code); body.append(string: message); body.append(string: "en")
        return body
    }

    private func attributes(_ info: stat) -> Data {
        var body = Data(); body.append(uint32: 0x1 | 0x4 | 0x8)
        body.append(uint64: UInt64(info.st_size)); body.append(uint32: UInt32(info.st_mode))
        body.append(uint32: UInt32(info.st_atimespec.tv_sec)); body.append(uint32: UInt32(info.st_mtimespec.tv_sec))
        return body
    }

    private func newHandle() -> Data { next += 1; return Data("h\(next)".utf8) }

    private func handle(_ reader: inout SSHWireReader) throws -> Data {
        let type = try reader.byte()
        if type == 1 { var body = Data([2]); body.append(uint32: 3); return body }
        let id = try reader.uint32()
        func path() throws -> String { String(decoding: try reader.string(), as: UTF8.self) }
        func errno(_ code: Int32) -> Data { status(id, code == ENOENT ? 2 : code == EACCES ? 3 : 4, String(cString: strerror(code))) }
        switch type {
        case 16:
            let requested = try path()
            var body = Data([104]); body.append(uint32: id); body.append(uint32: 1)
            body.append(string: requested == "." ? "/" : requested); body.append(string: ""); body.append(uint32: 0)
            return body
        case 7, 17:
            var info = stat()
            guard (type == 7 ? lstat(local(try path()), &info) : stat(local(try path()), &info)) == 0 else { return errno(Darwin.errno) }
            var body = Data([105]); body.append(uint32: id); body.append(attributes(info)); return body
        case 8:
            guard let fd = handles[try reader.string()] else { return status(id, 4) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { return errno(Darwin.errno) }
            var body = Data([105]); body.append(uint32: id); body.append(attributes(info)); return body
        case 11:
            let folder = local(try path())
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return status(id, 2) }
            let handle = newHandle()
            directories[handle] = (folder, [".", ".."] + names)
            var body = Data([102]); body.append(uint32: id); body.append(string: handle); return body
        case 12:
            let handle = try reader.string()
            guard let (folder, names) = directories[handle] else { return status(id, 4) }
            guard !names.isEmpty else { return status(id, 1) }
            directories[handle] = (folder, [])
            var body = Data([104]); body.append(uint32: id); body.append(uint32: UInt32(names.count))
            for name in names {
                var info = stat()
                _ = lstat((folder as NSString).appendingPathComponent(name), &info)
                body.append(string: name); body.append(string: name); body.append(attributes(info))
            }
            return body
        case 3:
            let file = local(try path())
            let flags = try reader.uint32()
            _ = try reader.uint32()
            var mode = O_CLOEXEC | O_NOFOLLOW
            mode |= flags & 0x2 != 0 ? (flags & 0x1 != 0 ? O_RDWR : O_WRONLY) : O_RDONLY
            if flags & 0x8 != 0 { mode |= O_CREAT }
            if flags & 0x20 != 0 { mode |= O_EXCL }
            let fd = open(file, mode, 0o644)
            guard fd >= 0 else { return errno(Darwin.errno) }
            let handle = newHandle()
            handles[handle] = fd
            var body = Data([102]); body.append(uint32: id); body.append(string: handle); return body
        case 4:
            let handle = try reader.string()
            if let fd = handles.removeValue(forKey: handle) { close(fd) }
            directories[handle] = nil
            return status(id, 0)
        case 5:
            guard let fd = handles[try reader.string()] else { return status(id, 4) }
            let offset = try reader.uint64(), length = Int(try reader.uint32())
            var bytes = [UInt8](repeating: 0, count: length)
            let count = pread(fd, &bytes, length, off_t(offset))
            guard count > 0 else { return count == 0 ? status(id, 1) : errno(Darwin.errno) }
            var body = Data([103]); body.append(uint32: id); body.append(string: Data(bytes.prefix(count))); return body
        case 6:
            guard let fd = handles[try reader.string()] else { return status(id, 4) }
            let offset = try reader.uint64(), data = try reader.string()
            let count = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
            return count == data.count ? status(id, 0) : errno(Darwin.errno)
        case 14: return mkdir(local(try path()), 0o755) == 0 ? status(id, 0) : errno(Darwin.errno)
        case 15: return rmdir(local(try path())) == 0 ? status(id, 0) : errno(Darwin.errno)
        case 13: return unlink(local(try path())) == 0 ? status(id, 0) : errno(Darwin.errno)
        case 18:
            let old = local(try path()), new = local(try path())
            return renamex_np(old, new, UInt32(RENAME_EXCL)) == 0 ? status(id, 0) : errno(Darwin.errno)
        default: return status(id, 8)
        }
    }
}
