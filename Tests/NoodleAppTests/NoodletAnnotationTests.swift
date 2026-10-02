import AppKit
import AppletBridge
import NoodleCore
import NoodleRuntime
import XCTest

@testable import Noodle

/// A noodlet opened from a conversation is annotated in place when the person presses the
/// Annotate Region shortcut in Noodle Applet, and the annotation goes back to that conversation.
@MainActor final class NoodletAnnotationTests: XCTestCase {
    private let notification = "NoodletAnnotationTests.\(UUID().uuidString)"
    private let session = UUID(), conversation = UUID()
    private let frame = CGRect(x: 140, y: 160, width: 420, height: 300)

    private func picture() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 840, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 840, height: 600))
        return try CaptureAttachment.png(try XCTUnwrap(context.makeImage()))
    }

    private func annotations(_ applet: FakeApplet, presented: @escaping (NoodletAnnotations.Capture) -> Void) -> NoodletAnnotations {
        NoodletAnnotations(applets: AppletController(connection: { try await applet.respond($0) }),
                           notification: notification, present: presented)
    }

    func testTheShortcutInAnOpenedNoodletAnnotatesItIntoItsConversation() async throws {
        let png = try picture()
        let applet = FakeApplet(session: session, frame: frame, png: png)
        var presented: [NoodletAnnotations.Capture] = []
        let annotations = annotations(applet) { presented.append($0) }
        annotations.listen()

        try await annotations.open(NoodletLink.url(for: UUID()), from: conversation,
                                   shortcut: KeyBinding("r", modifiers: [.command, .shift]))
        let opened = await applet.requests
        let open = try XCTUnwrap(opened.first)
        XCTAssertEqual(open.annotation, AppletAnnotation(notification: notification, key: "r", modifiers: 3))

        // Anything may post the notification; only a session Noodle opened is annotated.
        DistributedNotificationCenter.default().postNotificationName(.init(notification), object: UUID().uuidString,
                                                                     userInfo: nil, deliverImmediately: true)
        DistributedNotificationCenter.default().postNotificationName(.init(notification), object: session.uuidString,
                                                                     userInfo: nil, deliverImmediately: true)
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while presented.isEmpty, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(presented.count, 1)
        let capture = try XCTUnwrap(presented.first)
        XCTAssertEqual(capture.conversationID, conversation)
        XCTAssertEqual(capture.frame, frame)
        XCTAssertEqual(capture.title, "Board")
        XCTAssertEqual(capture.raw, png, "The whole picture arrives, piece by piece")
        let requests = await applet.requests
        let screenshots = requests.filter { $0.operation == .screenshot }
        XCTAssertEqual(screenshots.map(\.sessionID), [session])
    }

    func testWithoutAShortcutTheNoodletOffersNoAnnotation() async throws {
        let applet = FakeApplet(session: session, frame: frame, png: try picture())
        let annotations = annotations(applet) { _ in XCTFail("Nothing to annotate") }
        try await annotations.open(NoodletLink.url(for: UUID()), from: conversation, shortcut: nil)
        let opened = await applet.requests
        XCTAssertNil(try XCTUnwrap(opened.first).annotation)
        await annotations.annotate(session: session)
    }

    func testThePictureIsMarkedExactlyOverTheNoodletAndThenGoesAway() throws {
        let overlay = NoodletAnnotationOverlay()
        let capture = NoodletAnnotations.Capture(conversationID: conversation, title: "Board", raw: try picture(), frame: frame)
        overlay.present(capture) { _, _, _, _ in XCTFail("Nothing was saved") }
        let window = try XCTUnwrap(overlay.window)
        defer { window.close() }
        XCTAssertEqual(window.frame, frame)
        XCTAssertTrue(window.isVisible)
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
    }
}

/// Noodle Applet with one noodlet open, its screenshot sent in pieces.
private actor FakeApplet {
    let session: UUID, frame: CGRect, png: Data
    let artifact = UUID()
    var requests: [AppletRequest] = []
    init(session: UUID, frame: CGRect, png: Data) { self.session = session; self.frame = frame; self.png = png }

    func respond(_ request: AppletRequest) throws -> AppletResponse {
        try request.validate()
        requests.append(request)
        var response = AppletResponse()
        switch request.operation {
        case .open:
            response.sessionID = session
        case .screenshot:
            response.sessionID = session
            response.artifactID = artifact
            response.text = "Board"
            response.screenFrame = frame
        case .artifact:
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
