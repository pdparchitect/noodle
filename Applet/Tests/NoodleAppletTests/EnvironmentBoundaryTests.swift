import AppletBridge
import AppletCore
import XCTest
@testable import NoodleApplet

@MainActor final class EnvironmentBoundaryTests: XCTestCase {
    func testForeignCallerAndDocumentAreRejectedBeforeImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletEnvironment." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        let current = AppletBuildIdentity.current, other: AppletBuildIdentity = current == .production ? .development : .production
        var request = AppletRequest(.validate)
        request.path = "/source/Test." + current.fileExtension
        request.files = ["noodlet.json": Data(#"{"title":"Fixture","runtime":"html","entry":"index.html"}"#.utf8), "index.html": Data("fixture".utf8)]
        for peer in other.clientIDs {
            let response = await runtime.handle(request, identity: peer)
            XCTAssertEqual(response.errorCode, "environment-mismatch")
        }
        request.path = "/source/Test." + other.fileExtension
        let response = await runtime.handle(request, identity: current.noodleID)
        XCTAssertEqual(response.errorCode, "environment-mismatch")
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertTrue(runtime.sessions.isEmpty)
    }
}
