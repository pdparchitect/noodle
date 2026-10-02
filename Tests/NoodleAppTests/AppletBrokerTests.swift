import AppletBridge
import NoodleCore
import NoodleRuntime
import XCTest

@testable import Noodle

@MainActor final class AppletBrokerTests: XCTestCase {
    func testForeignConversationLinksNeverReachTheCompanion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let recorder = AppletRequestRecorder()
        let controller = AppletController(connection: { await recorder.respond($0) })
        let foreign: AppletBuildIdentity = AppletBuildIdentity.current == .production ? .development : .production
        let url = NoodletLink.url(for: UUID(), build: foreign)
        do { _ = try await controller.openNoodlet(url); XCTFail("Foreign link opened") }
        catch { XCTAssertEqual((error as? AppletError)?.code, "environment-mismatch") }
        do { _ = try await controller.resolvePreview(url); XCTFail("Foreign preview requested") }
        catch { XCTAssertEqual((error as? AppletError)?.code, "environment-mismatch") }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testAttachmentPreviewOnlyRequestsMetadataWithoutOpeningTheNoodlet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Preview.noodlet")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: package.appendingPathComponent("noodlet.json"))
        let id = UUID()
        var response = AppletResponse()
        response.noodletID = id
        response.title = "Preview"
        response.previewBookmark = try package.bookmarkData()
        let previewResponse = response
        let recorder = AppletRequestRecorder()
        let controller = AppletController(connection: {
            _ = await recorder.respond($0)
            return previewResponse
        })
        let preview = try await controller.resolvePreview(NoodletLink.url(for: id))
        XCTAssertEqual(preview.title, "Preview")
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.operation, .info)
        XCTAssertEqual(requests.first?.noodletID, id)
        XCTAssertEqual(requests.first?.includePreview, true)
        XCTAssertNil(requests.first?.mode)
    }

    /// The Shared popover shows what the conversation's card already loaded, without asking Applet again.
    func testSharedPopoverReusesTheCardTheConversationLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Flap.noodlet")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: package.appendingPathComponent("noodlet.json"))
        let id = UUID()
        var response = AppletResponse()
        response.noodletID = id
        response.title = "Flap"
        response.previewBookmark = try package.bookmarkData()
        let previewResponse = response
        let recorder = AppletRequestRecorder()
        let controller = AppletController(connection: {
            _ = await recorder.respond($0)
            return previewResponse
        })
        let url = NoodletLink.url(for: id)
        XCTAssertNil(NoodletAttachmentCard.shown(url))
        _ = try await NoodletAttachmentCard.load(url, from: controller)
        XCTAssertEqual(NoodletAttachmentCard.shown(url)?.title, "Flap")
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    /// Applet serves only a few connections at once and drops the rest, so the Shared popover's
    /// rows must not ask for every noodlet's preview together.
    func testNoodletPreviewsAreRequestedAFewAtATime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("Flap").appendingPathExtension(AppletBuildIdentity.current.fileExtension)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: package.appendingPathComponent("noodlet.json"))
        let bookmark = try package.bookmarkData()
        let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let png = try XCTUnwrap(pixel?.representation(using: .png, properties: [:]))
        let tracker = ConcurrencyTracker()
        let controller = AppletController(connection: { request in
            await tracker.enter()
            for _ in 0..<20 { await Task.yield() }
            await tracker.leave()
            var response = AppletResponse()
            response.noodletID = request.noodletID
            response.previewBookmark = bookmark
            response.data = png
            response.mediaType = "image/png"
            return response
        })
        let loads = (0..<8).map { _ in
            Task { try await NoodletAttachmentCard.load(NoodletLink.url(for: UUID()), from: controller) }
        }
        for load in loads { _ = try await load.value }
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 2)
    }

    func testAttachmentOpenRequestsTheLiveForegroundRuntimeAndReportsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        let recorder = AppletRequestRecorder()
        let controller = AppletController(connection: { await recorder.respond($0) })
        let id = UUID()
        _ = try await controller.openNoodlet(NoodletLink.url(for: id))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.operation, .open)
        XCTAssertEqual(requests.first?.mode, "foreground")
        XCTAssertEqual(requests.first?.noodletID, id)
        XCTAssertNil(requests.first?.includePreview)
        XCTAssertNil(requests.first?.path)
        do { _ = try await controller.openNoodlet(URL(string: "https://example.com")!); XCTFail("Web URL reached Applet") } catch {}
        let failed = AppletController(connection: { _ in AppletResponse(error: "This noodlet is no longer available.") })
        do { _ = try await failed.openNoodlet(NoodletLink.url(for: id)); XCTFail("Missing package appeared to open") }
        catch { XCTAssertEqual(error.localizedDescription, "This noodlet is no longer available.") }
    }
    /// Installing Noodle Applet gives every bot the applet tool, removing it takes the tool
    /// away, and neither restarts a harness.
    func testCompanionInstallAndRemovalGrantAndWithdrawTheTool() {
        let installed = Installed()
        let controller = AppletController(connection: { _ in AppletResponse() }, isInstalled: { installed.value })
        var grants: [[UUID: Set<String>]] = []
        controller.onGrantsChange = { grants.append($0) }
        let a = UUID(), b = UUID()
        controller.start(agents: [AgentRecord(id: a, displayName: "A"), AgentRecord(id: b, displayName: "B")])
        defer { controller.start(agents: []) }
        XCTAssertEqual(grants, [[:]])
        controller.refreshSkills()
        XCTAssertEqual(grants.count, 1, "Nothing changed, so nothing is published again")
        installed.value = true
        controller.refreshSkills()
        XCTAssertEqual(grants.last, [a: [AppletToolGrant.id], b: [AppletToolGrant.id]])
        let c = UUID()
        controller.start(agents: [AgentRecord(id: a, displayName: "A"), AgentRecord(id: b, displayName: "B"), AgentRecord(id: c, displayName: "C")])
        XCTAssertEqual(grants.last?[c], [AppletToolGrant.id])
        installed.value = false
        controller.refreshSkills()
        XCTAssertEqual(grants.last, [:])
    }

    /// The tool's way in carries a bot's request only: one naming its bot, never what Noodle and
    /// Noodle Hub ask for people.
    func testTheToolPassesOnlyBotRequestsThatNameTheirBot() async throws {
        let recorder = AppletRequestRecorder()
        let controller = AppletController(connection: { await recorder.respond($0) })
        var anonymous = AppletRequest(.list)
        anonymous.owner = nil
        var archive = AppletRequest(.archive)
        archive.noodletID = UUID(); archive.owner = UUID().uuidString
        // Only the person brings a noodlet to the foreground, by opening it.
        var shown = AppletRequest(.open)
        shown.noodletID = UUID(); shown.mode = "foreground"; shown.owner = UUID().uuidString
        for request in [anonymous, archive, shown, AppletRequest(.show, sessionID: UUID())] {
            do { _ = try await controller.tool(request); XCTFail("\(request.operation) reached Applet") } catch {}
        }
        var request = AppletRequest(.list)
        request.owner = UUID().uuidString.lowercased()
        let failed = AppletController(connection: { _ in var r = AppletResponse(error: "Compiler error"); r.sessionID = UUID(); return r })
        let response = try await failed.tool(request)
        XCTAssertEqual(response.error, "Compiler error", "Errors come back with their session, for logs")
        XCTAssertNotNil(response.sessionID)
        let sent = await recorder.requests
        XCTAssertTrue(sent.isEmpty)
    }
}
private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
private final class Installed: @unchecked Sendable {
    var value = false
}
private actor AppletRequestRecorder {
    var requests: [AppletRequest] = []
    func respond(_ request: AppletRequest) -> AppletResponse {
        requests.append(request)
        return AppletResponse()
    }
}
