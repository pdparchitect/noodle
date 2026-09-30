import AppletBridge
import XCTest

final class ConnectionPathTests: XCTestCase {
    /// A long home folder name must not push the connection past the platform's socket path limit.
    func testLongConnectionPathRegistersAndAnswers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(String(repeating: "x", count: 110))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.sock")
        let server = try AppletConnectionServer(socket: url, team: "1234567890") { _, _ in AppletResponse() }
        XCTAssertThrowsError(try AppletConnectionServer(socket: url, team: "1234567890") { _, _ in AppletResponse() }) {
            XCTAssertEqual($0.localizedDescription, "A applet provider is already running.")
        }
        withExtendedLifetime(server) {}
    }
}
