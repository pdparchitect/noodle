import Foundation
import Network
import XCTest
@testable import NoodleCore

/// The probe against a stand-in `opencode serve`: a script that announces an address and
/// waits for its input to close, and a loopback server answering the model API.
final class OpenCodeModelProbeTests: XCTestCase {
    private let models = Data(#"{"data":[{"providerID":"opencode","id":"alpha"},{"providerID":"opencode","id":"beta"}]}"#.utf8)
    private let preferred = Data(#"{"data":{"providerID":"opencode","id":"beta"}}"#.utf8)

    func testModelsAreReadWithTheProbesOwnPasswordAndDefault() throws {
        let server = try ModelServer(["/api/model": .ok(models), "/api/model/default": .ok(preferred)])
        let root = try root()
        let probe = try probe(root, announcing: server.address)
        defer { probe.stop() }
        let result = try probe.models()
        XCTAssertEqual(result.map(\.id), ["opencode/alpha", "opencode/beta"])
        XCTAssertEqual(result.filter(\.isDefault).map(\.id), ["opencode/beta"])
        let password = try String(contentsOf: root.appendingPathComponent("password"), encoding: .utf8)
        XCTAssertGreaterThanOrEqual(password.count, 72, "Each probe generates its own long password")
        let expected = "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
        XCTAssertEqual(server.requests.map(\.path), ["/api/model", "/api/model/default"])
        XCTAssertEqual(Set(server.requests.map(\.authorization)), [expected])
    }

    func testOnlyAPlainLoopbackAddressIsTrusted() throws {
        let server = try ModelServer(["/api/model": .ok(models)])
        let port = server.port
        for address in ["http://localhost:\(port)", "https://127.0.0.1:\(port)", "http://10.0.0.1:\(port)",
                        "http://user:secret@127.0.0.1:\(port)", "http://127.0.0.1:\(port)/api",
                        "http://127.0.0.1:\(port)/?next=1", "http://127.0.0.1", "not a url"] {
            let root = try root()
            XCTAssertThrowsError(try probe(root, announcing: address), address)
            XCTAssertFalse(try isRunning(root), "The rejected server must be stopped: \(address)")
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAServerThatExitsWithoutAnAddressFailsPromptly() throws {
        let root = try root()
        let script = root.appendingPathComponent("opencode")
        try Data("#!/bin/sh\nexit 3\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let started = Date()
        XCTAssertThrowsError(try OpenCodeModelProbe(executable: script, workspace: root, environment: [:], profile: Self.profile))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Exit must not wait out the startup timeout")
    }

    func testRedirectsAndFailedResponsesAreRefused() throws {
        let server = try ModelServer(["/api/model": .redirect("/elsewhere"), "/elsewhere": .ok(models),
                                      "/api/model/default": .status(401)])
        let probe = try probe(try root(), announcing: server.address)
        defer { probe.stop() }
        XCTAssertThrowsError(try probe.get("/api/model"))
        XCTAssertThrowsError(try probe.get("/api/model/default"))
        XCTAssertFalse(server.requests.map(\.path).contains("/elsewhere"), "Credentials must not follow a redirect")
    }

    func testStopEndsTheServer() throws {
        let server = try ModelServer(["/api/model": .ok(models)])
        let root = try root()
        let probe = try probe(root, announcing: server.address)
        XCTAssertTrue(try isRunning(root))
        probe.stop()
        XCTAssertFalse(try isRunning(root))
    }

    // MARK: - Fixture

    private static let profile = "(version 1)(allow default)"

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-probe-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Writes its password and pid, announces `address`, then lives until its input closes.
    private func probe(_ root: URL, announcing address: String) throws -> OpenCodeModelProbe {
        let script = root.appendingPathComponent("opencode")
        try Data("""
            #!/bin/sh
            printf %s "$OPENCODE_PASSWORD" > password
            echo $$ > pid
            printf '{"url":"%s"}\\n' "$PROBE_ADDRESS"
            cat > /dev/null

            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return try OpenCodeModelProbe(executable: script, workspace: root,
            environment: ["PROBE_ADDRESS": address, "OPENCODE_DISABLE_MODELS_FETCH": "1", "PATH": "/usr/bin:/bin"],
            profile: Self.profile)
    }

    private func isRunning(_ root: URL) throws -> Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        for _ in 0..<50 where kill(pid, 0) == 0 { Thread.sleep(forTimeInterval: 0.02) }
        return kill(pid, 0) == 0
    }
}

/// A loopback HTTP/1.1 server that answers each path with a fixed reply and records requests.
private final class ModelServer: @unchecked Sendable {
    enum Reply { case ok(Data), status(Int), redirect(String) }
    struct Request: Equatable { var path: String; var authorization: String? }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "opencode-probe-server")
    private let routes: [String: Reply]
    private let lock = NSLock()
    private var recorded: [Request] = []

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    var port: UInt16 { listener.port!.rawValue }
    var address: String { "http://127.0.0.1:\(port)" }

    init(_ routes: [String: Reply]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    deinit { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                return
            }
            self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let authorization = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        lock.lock(); recorded.append(Request(path: path, authorization: authorization)); lock.unlock()
        var status = "404 Not Found", headers = "", body = Data()
        switch routes[path] {
        case .ok(let data)?: status = "200 OK"; body = data; headers = "Content-Type: application/json\r\n"
        case .status(let code)?: status = "\(code) Error"
        case .redirect(let location)?: status = "302 Found"; headers = "Location: \(location)\r\n"
        case nil: break
        }
        let response = Data("HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
