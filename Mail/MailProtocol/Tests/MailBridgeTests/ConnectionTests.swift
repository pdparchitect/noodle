import Darwin
import XCTest
@testable import MailBridge

final class ConnectionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        // Short: a socket path must fit in 255 bytes.
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func pair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        MailConnection.configure(fds[0], seconds: 5); MailConnection.configure(fds[1], seconds: 5)
        addTeardownBlock { Darwin.close(fds[0]); Darwin.close(fds[1]) }
        return (fds[0], fds[1])
    }

    /// A frame is a 4-byte big-endian length and its bytes, read back whole.
    func testFramesRoundTripOverASocketPair() throws {
        let (a, b) = try pair()
        let payload = Data(#"{"operation":"mailboxes"}"#.utf8)
        try MailConnection.send(payload, a)
        XCTAssertEqual(try MailConnection.receive(b), payload)
    }

    /// Empty and oversized frames are refused on both ends.
    func testEmptyAndOversizedFramesAreRefused() throws {
        let (a, b) = try pair()
        XCTAssertThrowsError(try MailConnection.send(Data(), a))
        var count = UInt32(MailConnection.maxFrame + 1).bigEndian
        _ = withUnsafeBytes(of: &count) { Darwin.write(a, $0.baseAddress!, 4) }
        XCTAssertThrowsError(try MailConnection.receive(b)) { error in
            XCTAssertEqual((error as? MailError)?.message, "Invalid Mail message size.")
        }
    }

    /// Only one Noodle Mail serves a socket; a second one is refused.
    func testASecondServerOnTheSameSocketIsRefused() throws {
        let url = folder.appendingPathComponent("m.sock")
        let first = try MailConnectionServer(socket: url, team: "ABCDE12345") { _, _ in MailResponse() }
        XCTAssertThrowsError(try MailConnectionServer(socket: url, team: "ABCDE12345") { _, _ in MailResponse() }) { error in
            XCTAssertEqual((error as? MailError)?.message, "Noodle Mail is already running.")
        }
        withExtendedLifetime(first) {}
    }

    /// A socket file left behind by a crash is replaced.
    func testAStaleSocketIsReplaced() throws {
        let url = folder.appendingPathComponent("m.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertEqual(try MailConnection.withAddress(url) { Darwin.bind(fd, $0, $1) }, 0)
        Darwin.close(fd)
        XCTAssertNoThrow(try MailConnectionServer(socket: url, team: "ABCDE12345") { _, _ in MailResponse() })
    }

    /// With no app listening, a call reports Noodle Mail as unavailable so the caller can start it.
    func testAnUnreachableSocketIsUnavailable() async throws {
        do {
            _ = try await MailConnection.call(MailRequest(.mailboxes), socket: folder.appendingPathComponent("none.sock"), team: "ABCDE12345")
            XCTFail("Expected an error.")
        } catch let error as MailError {
            XCTAssertTrue(error.unavailable)
        }
    }

    /// A process that isn't a signed Noodle client gets an error and never reaches the handler.
    func testUnsignedClientsAreRefused() throws {
        let url = folder.appendingPathComponent("m.sock")
        let reached = expectation(description: "handler"); reached.isInverted = true
        let server = try MailConnectionServer(socket: url, team: "ABCDE12345") { _, _ in reached.fulfill(); return MailResponse() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        MailConnection.configure(fd, seconds: 10)
        XCTAssertEqual(try MailConnection.withAddress(url) { Darwin.connect(fd, $0, $1) }, 0)
        try MailConnection.send(JSONEncoder().encode(MailRequest(.mailboxes)), fd)
        let reply = try JSONDecoder().decode(MailResponse.self, from: MailConnection.receive(fd))
        XCTAssertNotNil(reply.error)
        wait(for: [reached], timeout: 0.5)
        withExtendedLifetime(server) {}
    }

    /// A socket path longer than Darwin allows is refused, not truncated.
    func testAnOverlongSocketPathIsRefused() {
        let url = URL(fileURLWithPath: "/" + String(repeating: "a", count: 300))
        XCTAssertThrowsError(try MailConnection.withAddress(url) { _, _ in 0 })
    }

    /// Discovery never picks an app in the Trash or one with another bundle id.
    func testDiscoveryNeverPicksTrashedOrForeignApps() {
        let good = URL(fileURLWithPath: "/Applications/Noodle Mail.app")
        let trashed = URL(fileURLWithPath: "/Users/me/.Trash/Noodle Mail.app")
        let foreign = URL(fileURLWithPath: "/Applications/Other.app")
        let identify: (URL) -> String? = { $0 == foreign ? "com.example.other" : "com.pdparchitect.noodle.mail" }
        XCTAssertEqual(MailApplication.select(running: [trashed, foreign], sibling: nil, registered: good, build: .production, identify: identify), good)
        XCTAssertNil(MailApplication.select(running: [trashed], sibling: nil, registered: nil, build: .production, identify: identify))
    }

    /// The tool extension finds a Dev companion beside the Noodle app that contains it.
    func testExtensionsLookBesideTheirApp() {
        let appex = URL(fileURLWithPath: "/Dev/Noodle Dev.app/Contents/Extensions/NoodleMailTools.appex")
        // By path: Foundation's deletingLastPathComponent() leaves a trailing slash that URL equality sees.
        XCTAssertEqual(MailApplication.containingApplication(of: appex).path, URL(fileURLWithPath: "/Dev/Noodle Dev.app").path)
        let app = URL(fileURLWithPath: "/Dev/Noodle Dev.app")
        XCTAssertEqual(MailApplication.containingApplication(of: app), app)
    }
}
