import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class MessageTextRenderingTests: XCTestCase {
    func testIncomingMessagePixelsRemainReadable() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let conversation = try fixture.group()
        let store = fixture.store
        for index in 0..<80 {
            try fixture.repository.append(ChatMessage(conversationID: conversation.id, author: .agent(fixture.a.id),
                body: "Earlier research message \(index)", delivery: .delivered))
        }
        try fixture.repository.append(ChatMessage(conversationID: conversation.id, author: .user,
            body: "I will review the research tomorrow", delivery: .delivered))
        store.refreshTranscripts()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: .init(x: 60, y: 60, width: 1000, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Message rendering regression"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: MessageRenderingChat(store: store))
        defer { window.close(); window.contentView = nil }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        store.selectedConversationID = fixture.directA.id
        try await Task.sleep(for: .milliseconds(200))
        store.selectedConversationID = conversation.id
        // The first incoming reply arrives during the conversation dissolve.
        try await Task.sleep(for: .milliseconds(30))
        for body in ["Understood, I will leave the research with you for review.",
                     "Take your time reviewing. I will wait for your direction.\nThis is the second line of the reply.",
                     "No applications or introductions until you say so."] {
            try fixture.repository.append(ChatMessage(conversationID: conversation.id, author: .agent(fixture.a.id),
                body: body, delivery: .delivered))
            store.refreshTranscripts()
            try await Task.sleep(for: .milliseconds(200))
        }
        try await assertReadable(window)
        // Resize and recreate the conversation, exercising virtualized rows and
        // the native transition surface as well as newly appended messages.
        window.setContentSize(.init(width: 720, height: 650))
        store.selectedConversationID = fixture.directA.id
        try await Task.sleep(for: .milliseconds(250))
        store.selectedConversationID = conversation.id
        try await Task.sleep(for: .milliseconds(400))
        try await assertReadable(window)
    }

    /// Mirrored text stays mirrored until its row is rebuilt, so the check retries until the text reads:
    /// a slow machine or a failed capture is not a regression, text that never reads is.
    private func assertReadable(_ window: NSWindow) async throws {
        let expected = ["I will review the research tomorrow", "Understood", "Take your time reviewing",
                        "This is the second line", "No applications or introductions"]
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        var text = "", failure: Error?
        repeat {
            do {
                text = try await recognizedText(window)
                failure = nil
                if expected.allSatisfy(text.contains) { return }
            } catch { failure = error }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < end
        if let failure { throw failure }
        for phrase in expected where !text.contains(phrase) {
            XCTFail("Missing upright message pixels: \(phrase). Recognized: \(text)")
        }
    }

    private func recognizedText(_ window: NSWindow) async throws -> String {
        let content = try await SCShareableContent.currentProcess
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * 2)
        config.height = Int(target.frame.height * 2)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        // Keep the visual regression independent of Neural Engine startup.
        request.usesCPUOnly = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

private struct MessageRenderingChat: View {
    let store: NoodleStore
    @State private var preview = AttachmentPreviewController()
    var body: some View {
        if let conversation = store.selectedConversation {
            ChatView(conversation: conversation, attachmentPreview: preview).environment(store)
        }
    }
}
