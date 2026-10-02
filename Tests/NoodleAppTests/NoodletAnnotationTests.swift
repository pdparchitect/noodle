import AppKit
import AppletBridge
import NoodleCore
import NoodleRuntime
import XCTest

@testable import Noodle

/// A noodlet opened from a conversation is annotated in place when the person presses the
/// Annotate Region or Add Annotation shortcut in Noodle Applet, and the annotation goes back to
/// that conversation.
@MainActor final class NoodletAnnotationTests: XCTestCase {
    private let notification = "NoodletAnnotationTests.\(UUID().uuidString)"
    private let session = UUID(), conversation = UUID()
    private let frame = CGRect(x: 140, y: 160, width: 420, height: 300)
    private let windowFrame = CGRect(x: 140, y: 160, width: 420, height: 328)
    private let region = KeyBinding("r", modifiers: [.command, .shift])
    private let selection = KeyBinding("a", modifiers: [.command, .shift])

    private func picture() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 840, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 840, height: 600))
        return try CaptureAttachment.png(try XCTUnwrap(context.makeImage()))
    }

    private func applet() throws -> FakeApplet {
        FakeApplet(session: session, frame: frame, windowFrame: windowFrame, png: try picture())
    }

    private func annotations(_ applet: FakeApplet, presented: @escaping (NoodletAnnotations.Capture) -> Void) -> NoodletAnnotations {
        NoodletAnnotations(applets: AppletController(connection: { try await applet.respond($0) }),
                           notification: notification, present: presented)
    }

    private func post(_ kind: String, _ object: String) {
        DistributedNotificationCenter.default().postNotificationName(.init("\(notification).\(kind)"), object: object,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    private func waitFor(_ presented: () -> [NoodletAnnotations.Capture]) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while presented().isEmpty, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
    }

    func testTheRegionShortcutInAnOpenedNoodletMarksItsPictureIntoItsConversation() async throws {
        let applet = try applet()
        var presented: [NoodletAnnotations.Capture] = []
        let annotations = annotations(applet) { presented.append($0) }
        annotations.listen()

        try await annotations.open(NoodletLink.url(for: UUID()), from: conversation, region: region, selection: selection)
        let opened = await applet.requests
        XCTAssertEqual(try XCTUnwrap(opened.first).annotation, AppletAnnotation(
            application: Bundle.main.bundleIdentifier ?? "", notification: notification,
            region: .init(key: "r", modifiers: 3), selection: .init(key: "a", modifiers: 3)))

        // Anything may post the notification; only a session Noodle opened is annotated.
        post("region", UUID().uuidString)
        post("region", session.uuidString)
        try await waitFor { presented }

        XCTAssertEqual(presented.count, 1)
        let capture = try XCTUnwrap(presented.first)
        XCTAssertEqual(capture.conversationID, conversation)
        XCTAssertEqual(capture.frame, frame)
        XCTAssertEqual(capture.windowFrame, windowFrame)
        XCTAssertEqual(capture.title, "Board")
        XCTAssertNil(capture.quote)
        XCTAssertEqual(capture.raw, applet.png, "The whole picture arrives, piece by piece")
        let requests = await applet.requests
        XCTAssertEqual(requests.filter { $0.operation == .screenshot }.map(\.sessionID), [session])
    }

    func testTheSelectionShortcutQuotesTheSelectedTextOfThePage() async throws {
        let applet = try applet()
        var presented: [NoodletAnnotations.Capture] = []
        let annotations = annotations(applet) { presented.append($0) }
        annotations.listen()
        try await annotations.open(NoodletLink.url(for: UUID()), from: conversation, region: region, selection: selection)

        post("selection", session.uuidString)
        try await waitFor { presented }

        let capture = try XCTUnwrap(presented.first)
        XCTAssertEqual(capture.quote, "Level 3")
        XCTAssertEqual(String(decoding: capture.raw, as: UTF8.self), "Board\n\nScore 120\nLevel 3")
        XCTAssertEqual(capture.frame, frame)
        let requests = await applet.requests
        XCTAssertEqual(requests.filter { $0.operation == .eval }.map(\.sessionID), [session])
    }

    func testWithoutShortcutsTheNoodletOffersNoAnnotation() async throws {
        let applet = try applet()
        let annotations = annotations(applet) { _ in XCTFail("Nothing to annotate") }
        try await annotations.open(NoodletLink.url(for: UUID()), from: conversation, region: nil, selection: nil)
        let opened = await applet.requests
        XCTAssertNil(try XCTUnwrap(opened.first).annotation)
        await annotations.annotate(session: session, selection: false)
    }

    func testThePictureIsMarkedExactlyOverTheNoodletWithTheRestOfItsWindowShielded() throws {
        let overlay = NoodletAnnotationOverlay()
        let capture = NoodletAnnotations.Capture(conversationID: conversation, title: "Board", raw: try picture(),
                                                 quote: nil, frame: frame, windowFrame: windowFrame)
        overlay.present(capture) { _, _, _, _ in XCTFail("Nothing was saved") }
        let window = try XCTUnwrap(overlay.window)
        defer { window.close() }
        XCTAssertEqual(window.frame, frame)
        XCTAssertTrue(window.isVisible)
        let shield = try XCTUnwrap(window.childWindows?.first { $0.frame == windowFrame },
                                   "Nothing of the noodlet's window can be dragged while it is marked")
        XCTAssertFalse(shield.ignoresMouseEvents)
        let editor = try XCTUnwrap(overlay.editor)
        XCTAssertNotNil(editor.conversationCanvas, "The person marks a region straight away")
        // A second press while marking does not stack another picture on top.
        overlay.present(capture) { _, _, _, _ in }
        XCTAssertTrue(overlay.window === window)

        editor.cancelAnnotation()
        let end = Date().addingTimeInterval(2)
        while overlay.window != nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNil(overlay.window)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(shield.isVisible)
    }

    func testASelectionGoesStraightToItsComment() throws {
        let overlay = NoodletAnnotationOverlay()
        let capture = NoodletAnnotations.Capture(conversationID: conversation, title: "Board",
                                                 raw: Data("Board\n\nLevel 3".utf8), quote: "Level 3",
                                                 frame: frame, windowFrame: windowFrame)
        overlay.present(capture) { _, _, _, _ in }
        let window = try XCTUnwrap(overlay.window)
        defer { window.close() }
        let editor = try XCTUnwrap(overlay.editor)
        XCTAssertNil(editor.conversationCanvas)
        XCTAssertNotNil(editor.commentPopover)
        editor.cancelAnnotation()
    }
}

/// Noodle Applet with one noodlet open, its screenshot sent in pieces.
private actor FakeApplet {
    let session: UUID, frame: CGRect, windowFrame: CGRect, png: Data
    let artifact = UUID()
    var requests: [AppletRequest] = []
    init(session: UUID, frame: CGRect, windowFrame: CGRect, png: Data) {
        self.session = session; self.frame = frame; self.windowFrame = windowFrame; self.png = png
    }

    func respond(_ request: AppletRequest) throws -> AppletResponse {
        try request.validate()
        requests.append(request)
        var response = AppletResponse()
        response.sessionID = session
        response.title = "Board"
        response.screenFrame = frame
        response.windowFrame = windowFrame
        switch request.operation {
        case .open: break
        case .screenshot:
            response.artifactID = artifact
            response.text = "Board"
        case .eval:
            response.value = #"{"selection":"Level 3","text":"Score 120\nLevel 3"}"#
        case .artifact:
            response = AppletResponse()
            let offset = request.offset ?? 0
            let piece = png[offset..<min(png.count, offset + png.count / 2 + 1)]
            response.data = Data(piece)
            response.offset = offset + piece.count
            response.done = response.offset == png.count
        default:
            response.error = "Unexpected"
        }
        return response
    }
}
