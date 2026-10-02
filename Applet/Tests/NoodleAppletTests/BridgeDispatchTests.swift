import AppletCore
import XCTest

@testable import NoodleApplet

/// Pins the noodlet bridge contract as Applet answers it. The WebKit callback takes a
/// WKScriptMessage, which has no public initializer, so the dispatch is exercised directly.
final class BridgeDispatchTests: XCTestCase {
    @MainActor private func makeRunner() throws -> (WebRunner, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = try NoodletPackage.install([
            "noodlet.json": Data(#"{"version":1,"title":"Bridge","runtime":"html","entry":"index.html"}"#.utf8),
            "index.html": Data("<title>Bridge</title>".utf8),
        ], to: root.appendingPathComponent("Bridge.noodlet"))
        let dataRoot = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let runner = WebRunner(
            package: package, dataRoot: dataRoot, log: AppletLog(url: root.appendingPathComponent("log.txt")), size: CGSize(width: 320, height: 240),
            storeID: UUID(), rememberFrame: false, testClock: true)
        return (runner, root, dataRoot)
    }

    // MARK: - Dispatch

    @MainActor func testUnknownOperationIsRejected() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let (value, error) = await runner.handleBridge(operation: "wat", body: ["operation": "wat"])
        XCTAssertNil(value)
        XCTAssertEqual(error, "Unknown bridge operation.")
    }

    @MainActor func testWriteThenReadRoundTripsThroughTheDataFolder() async throws {
        let (runner, root, dataRoot) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }

        let wrote = await runner.handleBridge(
            operation: "write", body: ["operation": "write", "path": "notes/today.txt", "data": Data("hello".utf8).base64EncodedString()])
        XCTAssertEqual(wrote.0 as? Bool, true)
        XCTAssertNil(wrote.1)
        XCTAssertEqual(
            try String(contentsOf: dataRoot.appendingPathComponent("notes/today.txt"), encoding: .utf8), "hello")

        let read = await runner.handleBridge(
            operation: "read", body: ["operation": "read", "path": "notes/today.txt"])
        XCTAssertEqual(read.0 as? String, Data("hello".utf8).base64EncodedString())
        XCTAssertNil(read.1)
    }

    @MainActor func testReadingAMissingFileYieldsNullRatherThanAnError() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let (value, error) = await runner.handleBridge(
            operation: "read", body: ["operation": "read", "path": "absent.txt"])
        XCTAssertTrue(value is NSNull)
        XCTAssertNil(error)
    }

    @MainActor func testDataPathsCannotEscapeTheDataFolder() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../escaped.txt", "../../escaped.txt", "/etc/passwd", "notes/../../escaped.txt"] {
            let (value, error) = await runner.handleBridge(
                operation: "write", body: ["operation": "write", "path": path, "text": "x"])
            XCTAssertNil(value, "escaped with \(path)")
            XCTAssertNotNil(error, "escaped with \(path)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
    }

    @MainActor func testAMissingDataPathIsRejected() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let (value, error) = await runner.handleBridge(operation: "read", body: ["operation": "read"])
        XCTAssertNil(value)
        XCTAssertEqual(error, "A relative data path is required.")
    }

    @MainActor func testOversizedWritesAreRejected() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let tooBig = Data(count: 16 * 1_048_576 + 1).base64EncodedString()
        let (value, error) = await runner.handleBridge(
            operation: "write", body: ["operation": "write", "path": "big.bin", "data": tooBig])
        XCTAssertNil(value)
        XCTAssertEqual(error, "Data must fit in 16 MiB.")
    }

    @MainActor func testLoggingAndCancelFetchAcknowledge() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let logged = await runner.handleBridge(
            operation: "log", body: ["operation": "log", "level": "warn", "text": "careful"])
        XCTAssertEqual(logged.0 as? Bool, true)
        XCTAssertNil(logged.1)

        let cancelled = await runner.handleBridge(
            operation: "cancelFetch", body: ["operation": "cancelFetch", "id": UUID().uuidString])
        XCTAssertEqual(cancelled.0 as? Bool, true)
        XCTAssertNil(cancelled.1)
    }

    @MainActor func testRenderingStateIsDecodedAndStored() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let state: [String: Any] = [
            "readyState": "complete", "visibilityState": "visible",
            "nativeVisibilityState": "visible", "synthetic": false, "animationFrameCount": 3,
        ]
        let (value, error) = await runner.handleBridge(
            operation: "rendering", body: ["operation": "rendering", "state": state])
        XCTAssertNil(error)
        XCTAssertEqual(value as? Bool, true)
        XCTAssertEqual(runner.rendering?.readyState, "complete")
        XCTAssertEqual(runner.rendering?.animationFrameCount, 3)

        // A malformed state is reported, and never overwrites the last good one.
        let (bad, badError) = await runner.handleBridge(
            operation: "rendering", body: ["operation": "rendering", "state": ["mode": "idle"]])
        XCTAssertNil(bad)
        XCTAssertNotNil(badError)
        XCTAssertEqual(runner.rendering?.readyState, "complete")
    }

    @MainActor func testTheOldFileDialogOperationsAreGone() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        for operation in ["openFile", "saveFile"] {
            let (value, error) = await runner.handleBridge(
                operation: operation, body: ["operation": operation, "text": "x", "name": "a.txt"])
            XCTAssertNil(value, operation)
            XCTAssertEqual(error, "Unknown bridge operation.", operation)
        }
    }

    @MainActor func testWindowDraggingRequiresARecentMouseDown() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let (value, error) = await runner.handleBridge(
            operation: "dragWindow", body: ["operation": "dragWindow"])
        XCTAssertNil(value)
        XCTAssertNotNil(error)
    }

    @MainActor func testWindowActionsAnswerFalseOutOfSight() async throws {
        let (runner, root, _) = try makeRunner()
        defer { try? FileManager.default.removeItem(at: root) }
        let (value, error) = await runner.handleBridge(
            operation: "window", body: ["operation": "window", "action": "minimize"])
        XCTAssertNil(error)
        XCTAssertEqual(value as? Bool, false)
        let (unknown, unknownError) = await runner.handleBridge(
            operation: "window", body: ["operation": "window", "action": "maximize"])
        XCTAssertNil(unknown)
        XCTAssertEqual(unknownError, "Unknown window action.")
    }
}
