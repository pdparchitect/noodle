import AppletBridge
import AppletCore
import NoodleLaunchChecks
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

    /// A noodlet a bot sent says which folder it came from, so whoever links to it can tell whose
    /// it is: Applet keeps its own copy and does not decide that itself.
    func testANoodletSaysWhereItCameFrom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletSource." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        let current = AppletBuildIdentity.current
        var request = AppletRequest(.validate)
        request.path = "/Bots/Kai/Counter." + current.fileExtension
        request.files = ["noodlet.json": Data(#"{"title":"Counter","runtime":"html","entry":"index.html"}"#.utf8), "index.html": Data("0".utf8)]
        let validated = await runtime.handle(request, identity: current.noodleID)
        XCTAssertNil(validated.error)
        let id = try XCTUnwrap(validated.noodletID)
        XCTAssertNotEqual(validated.path, request.path, "Applet shows its own copy, not the bot's folder")
        var info = AppletRequest(.info)
        info.noodletID = id
        let described = await runtime.handle(info, identity: current.noodleID)
        XCTAssertNil(described.error)
        XCTAssertEqual(described.sourcePath, request.path)

        // Noodle Hub may show its picture on a card, but gets no way into the package.
        info.includePreview = true
        let hubPreview = await runtime.handle(info, identity: current.hubID)
        XCTAssertNil(hubPreview.error)
        XCTAssertNil(hubPreview.previewBookmark)
    }

    /// Each digest must match the argument named beside it in App.swift.
    func testLaunchCheckDigestsMatchTheirArguments() {
        XCTAssertEqual(AppletLaunchCheck.updaterUI, LaunchChecks.digest("--updater-ui-test"))
        XCTAssertEqual(AppletLaunchCheck.rendering, LaunchChecks.digest("--rendering-test"))
        XCTAssertEqual(AppletLaunchCheck.backgroundLaunchUI, LaunchChecks.digest("--background-launch-ui-test"))
        #if NOODLE_DEV_HOOKS
        XCTAssertEqual(AppletLaunchCheck.launchCapture, LaunchChecks.digest("--launch-check"))
        #endif
    }
}
