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

    /// A bot's noodlet is used where it is, so its size is up to the bot.
    func testABotNoodletOverTwentyMegabytesValidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLargePackage." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        var request = AppletRequest(.validate)
        let path = try botNoodlet(htmlNoodlet("Film"), named: "Film", owner: "ada", root: root)
        try Data(count: 21 * 1_048_576).write(to: URL(fileURLWithPath: path).appendingPathComponent("film.mp4"))
        request.path = path
        request.owner = "ada"
        let response = await runtime.handle(request, identity: AppletBuildIdentity.current.noodleID)
        XCTAssertNil(response.error)
        XCTAssertEqual(response.state, "valid")
    }

    /// Noodle Hub passes on its bots' requests as Noodle does, each for the bot that asked: a Hub
    /// bot reaches only its own noodlets, while the Hub itself, asking for nobody, reaches any.
    func testAHubBotReachesOnlyItsOwnNoodlets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletHubOwners." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        let hub = AppletBuildIdentity.current.hubID
        let own = try botNoodlet(htmlNoodlet("Board"), named: "Board", owner: "ada", root: root, hub: true)
        let theirs = try botNoodlet(htmlNoodlet("Diary"), named: "Diary", owner: "kai", root: root, hub: true)
        library.scan()

        var list = AppletRequest(.list)
        list.owner = "ada"
        let listed = await runtime.handle(list, identity: hub)
        XCTAssertEqual(listed.items?.map(\.path), [own])

        var info = AppletRequest(.info)
        info.noodletID = try library.linkID(for: NoodletPackage(url: URL(fileURLWithPath: theirs)))
        info.owner = "ada"
        let refused = await runtime.handle(info, identity: hub)
        XCTAssertEqual(refused.errorCode, "session-unavailable")

        info.owner = nil
        let described = await runtime.handle(info, identity: hub)
        XCTAssertNil(described.error)
        XCTAssertEqual(described.path, theirs)
    }

    /// A bot's noodlet is used where the bot keeps it, and says so, so whoever links to it can
    /// tell whose it is. Applet keeps no copy, and no other bot can use it.
    func testABotsNoodletIsUsedInItsOwnFolderAndOnlyByThatBot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletSource." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        let current = AppletBuildIdentity.current
        let path = try botNoodlet(htmlNoodlet("Counter"), named: "Counter", owner: "kai", root: root)
        var request = AppletRequest(.validate)
        request.path = path
        request.owner = "kai"
        let validated = await runtime.handle(request, identity: current.noodleID)
        XCTAssertNil(validated.error)
        let id = try XCTUnwrap(validated.noodletID)
        XCTAssertEqual(validated.path, path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.documents.appendingPathComponent("Imports").path))
        var info = AppletRequest(.info)
        info.noodletID = id
        let described = await runtime.handle(info, identity: current.noodleID)
        XCTAssertNil(described.error)
        XCTAssertEqual(described.sourcePath, path)

        request.owner = "ada"
        let refused = await runtime.handle(request, identity: current.noodleID)
        XCTAssertNotNil(refused.error)
        var list = AppletRequest(.list)
        list.owner = "ada"
        let listed = await runtime.handle(list, identity: current.noodleID)
        XCTAssertEqual(listed.items?.count ?? 0, 0)

        // Noodle Hub may show its picture on a card, but gets no way into the package.
        info.includePreview = true
        let hubPreview = await runtime.handle(info, identity: current.hubID)
        XCTAssertNil(hubPreview.error)
        XCTAssertNil(hubPreview.previewBookmark)
    }

    /// A request from a newer app says which app to update, not that data could not be read.
    func testARequestFromANewerAppNamesTheAppToUpdate() {
        let newer = #"{"version":1,"id":"00000000-0000-0000-0000-00000000000A","operation":"surface-teleport"}"#
        XCTAssertThrowsError(try AppletRequest.read(Data(newer.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "This needs a newer \(AppletBuildIdentity.current.appName). Update it.")
        }
    }

    /// Each digest must match the argument named beside it in App.swift.
    func testLaunchCheckDigestsMatchTheirArguments() {
        XCTAssertEqual(AppletLaunchCheck.updaterUI, LaunchChecks.digest("--updater-ui-test"))
        XCTAssertEqual(AppletLaunchCheck.rendering, LaunchChecks.digest("--rendering-test"))
        XCTAssertEqual(AppletLaunchCheck.smoke, LaunchChecks.digest("--smoke-test"))
        XCTAssertEqual(AppletLaunchCheck.backgroundLaunchUI, LaunchChecks.digest("--background-launch-ui-test"))
        #if NOODLE_DEV_HOOKS
        XCTAssertEqual(AppletLaunchCheck.launchCapture, LaunchChecks.digest("--launch-check"))
        #endif
    }
}
