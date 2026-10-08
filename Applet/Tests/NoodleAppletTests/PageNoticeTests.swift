import AppKit
import AppletBridge
import AppletCore
import Darwin
import Surface
import XCTest

@testable import NoodleApplet
@testable import NoodletRuntime

/// A noodlet's window keeps clear what its manifest asks to see through, and those watching it
/// live hear when its page is not responding.
@MainActor final class PageNoticeTests: XCTestCase {
    private func open(_ manifest: NoodletManifest, html: String) async throws -> AppletSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PageNotice." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        var request = AppletRequest(.open)
        request.path = try botNoodlet([
            "noodlet.json": try JSONEncoder().encode(manifest), "index.html": Data(html.utf8),
        ], named: manifest.title, owner: "author", root: library.root)
        request.owner = "author"
        request.mode = "background"
        let response = try await runtime.handle(request, identity: AppletBuildIdentity.current.noodleID).checked()
        let session = try XCTUnwrap(runtime.sessions[try XCTUnwrap(response.sessionID)])
        addTeardownBlock { await MainActor.run { session.stop() } }
        runtimes.append(runtime)
        return session
    }
    private var runtimes: [AppletRuntime] = []

    func testOnlyAnOpaqueWindowHasThePagePaintItsBackground() async throws {
        let opaque = try await open(NoodletManifest(title: "Opaque"), html: "<p>Hello</p>")
        XCTAssertEqual(opaque.web?.page.opaque, true)
        var frosted = NoodletManifest(title: "Frosted")
        frosted.window = NoodletWindowOptions()
        frosted.window?.background = .translucent
        let translucent = try await open(frosted, html: "<p>Hello</p>")
        XCTAssertEqual(translucent.web?.page.opaque, false)
    }

    func testLiveViewersHearWhenThePageIsNotResponding() async throws {
        let session = try await open(NoodletManifest(title: "Busy"), html: """
            <script>addEventListener('load', () => setTimeout(() => {
              const end = Date.now() + 3000; while (Date.now() < end) {}
            }, 1000))</script>
            """)
        let page = try XCTUnwrap(session.web?.page)
        page.responsiveness.unansweredFor = .milliseconds(300)
        page.beat = .milliseconds(100)
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let applet = SurfaceSocket(fd: fds[0]), viewer = SurfaceSocket(fd: fds[1])
        defer { applet.close(); viewer.close() }
        _ = try await runtimes[0].handle(
            AppletRequest(.surfaceStream, sessionID: session.id), identity: AppletBuildIdentity.current.noodleID,
            surface: applet).checked()
        let listening = Task {
            var heard: [SurfaceNotice?] = []
            for await frame in viewer.frames {
                if let status = SurfaceStatus(frame) { heard.append(status.notice) }
                if heard.count == 2 { break }
            }
            return heard
        }
        let timeout = Task { try await Task.sleep(for: .seconds(15)); listening.cancel() }
        defer { timeout.cancel() }
        let heard = await listening.value
        XCTAssertEqual(heard, [.notResponding, nil])
    }
}
