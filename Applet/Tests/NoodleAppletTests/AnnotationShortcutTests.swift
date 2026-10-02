import AppKit
import AppletBridge
import AppletCore
import XCTest

@testable import NoodleApplet

/// A noodlet Noodle opened from a conversation passes the person's annotation shortcut back to
/// Noodle, which annotates it in place; one opened in Applet itself has no conversation to go to.
@MainActor final class AnnotationShortcutTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private var runtime: AppletRuntime!
    private var library: AppletLibrary!
    private let notification = "AnnotationShortcutTests.\(UUID().uuidString)"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "AnnotationShortcut." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        library = botLibrary(root: root, defaults: defaults)
        runtime = AppletRuntime(library: library, defaults: defaults)
    }

    override func tearDown() async throws {
        for session in runtime.sessions.values { session.stop() }
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }

    private func install() async throws -> (NoodletPackage, UUID) {
        var validate = AppletRequest(.validate)
        validate.path = try botNoodlet([
            "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Board")),
            "index.html": Data("<title>Board</title>".utf8),
        ], named: "Board", owner: "author", root: library.root)
        validate.owner = "author"
        let response = try await runtime.handle(validate, identity: AppletBuildIdentity.current.noodleID).checked()
        let id = try XCTUnwrap(response.noodletID)
        return (try library.package(for: id), id)
    }

    /// ⇧⌘R and ⇧⌘A, as Noodle sends them.
    private var annotation: AppletAnnotation {
        AppletAnnotation(application: "com.example.noodle", notification: notification,
                         region: .init(key: "r", modifiers: 3), selection: .init(key: "a", modifiers: 3))
    }

    private func press(_ key: String, keyCode: UInt16, in window: NSWindow) throws {
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key.uppercased(),
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)))
    }

    /// What Noodle was asked to annotate within a second of `action`, as `kind session`.
    private func posted(during action: () throws -> Void) async throws -> [String] {
        var received: [String] = []
        let observers = ["region", "selection"].map { kind in
            DistributedNotificationCenter.default().addObserver(
                forName: .init("\(notification).\(kind)"), object: nil, queue: .main) { note in
                    MainActor.assumeIsolated { received.append("\(kind) \(note.object as? String ?? "")") }
                }
        }
        defer { observers.forEach(DistributedNotificationCenter.default().removeObserver) }
        try action()
        let end = ContinuousClock.now.advanced(by: .seconds(1))
        while received.isEmpty, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        return received
    }

    func testTheShortcutsInANoodletOpenedFromNoodleAskNoodleToAnnotateIt() async throws {
        let (_, id) = try await install()
        var open = AppletRequest(.open)
        open.noodletID = id
        open.mode = "foreground"
        open.annotation = annotation
        let opened = try await runtime.handle(open, identity: AppletBuildIdentity.current.noodleID).checked()
        let session = try XCTUnwrap(runtime.sessions[try XCTUnwrap(opened.sessionID)])
        let web = try XCTUnwrap(session.web)

        let region = try await posted { try press("r", keyCode: 15, in: web.window) }
        XCTAssertEqual(region, ["region \(session.id.uuidString)"])
        let selection = try await posted { try press("a", keyCode: 0, in: web.window) }
        XCTAssertEqual(selection, ["selection \(session.id.uuidString)"])

        // Any answer about the session says where it is, so Noodle can cover all of it.
        let status = try await runtime.handle(AppletRequest(.status, sessionID: session.id),
                                              identity: AppletBuildIdentity.current.noodleID).checked()
        XCTAssertEqual(status.screenFrame, web.window.convertToScreen(web.web.convert(web.web.bounds, to: nil)),
                       "Noodle lays the annotation exactly over the page")
        XCTAssertEqual(status.windowFrame, web.window.frame, "and shields the rest of the window")
    }

    func testANoodletOpenedInAppletHasNoConversationToAnnotateInto() async throws {
        let (package, _) = try await install()
        let opened = try await runtime.openInForeground(package).checked()
        let session = try XCTUnwrap(runtime.sessions[try XCTUnwrap(opened.sessionID)])
        let sessions = try await posted { try press("r", keyCode: 15, in: try XCTUnwrap(session.web).window) }
        XCTAssertEqual(sessions, [])
    }

    func testOnlyAForegroundOpenTakesAnAnnotationShortcut() throws {
        var background = AppletRequest(.open)
        background.mode = "background"
        background.annotation = annotation
        XCTAssertThrowsError(try background.validate())
        var unset = AppletRequest(.open)
        unset.mode = "foreground"
        unset.annotation = AppletAnnotation(application: "com.example.noodle", notification: notification,
                                            region: .init(key: "r", modifiers: 0), selection: nil)
        XCTAssertThrowsError(try unset.validate())
        unset.annotation = AppletAnnotation(application: "com.example.noodle", notification: notification,
                                            region: nil, selection: nil)
        XCTAssertThrowsError(try unset.validate())
    }
}
