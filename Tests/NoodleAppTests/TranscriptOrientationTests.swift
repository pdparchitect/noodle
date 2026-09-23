import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest
import NoodleCore
import NoodleWallpaper
@testable import Noodle

@MainActor final class TranscriptOrientationTests: XCTestCase {
    private static let reply = """
    Done: **Flux Racer** now has a second circuit, **Emerald Monsoon**. A light monsoon.

    What is different from the city track:

    - A whole new jungle engine instead of the cityscape, with buttress roots.
    - Heavy rain and lightning with a wet-asphalt look and post-rain reflections.
    - Set pieces: a stone tunnel, a dark cave mouth, and a moving beacon.
    - A longer, twistier layout that climbs, drops, and has a jungle hairpin.
    """
    private static let phrases = ["jungle engine", "wet-asphalt look", "moving beacon", "jungle hairpin"]

    func testAnIncomingReplyStaysUprightAcrossConversationSwitches() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanUp() }
        let conversation = try fixture.group()
        let store = fixture.store
        for index in 0..<60 {
            try fixture.repository.append(ChatMessage(conversationID: conversation.id, author: .agent(fixture.a.id),
                body: "Earlier research message \(index)", delivery: .delivered))
        }
        store.refreshTranscripts()

        NSApplication.shared.setActivationPolicy(.accessory)
        let columns = ColumnModel()
        let window = NSWindow(contentRect: .init(x: 60, y: 60, width: 1000, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "TranscriptOrientation")
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: OrientationChat(store: store, columns: columns))
        defer { window.close(); window.contentView = nil }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(600))

        let triggers: [(String, @MainActor (NSWindow) async -> Void)] = [
            ("plain", { _ in }),
            ("rapid-switch", { _ in
                for _ in 0..<8 {
                    store.selectedConversationID = fixture.directB.id
                    try? await Task.sleep(for: .milliseconds(12))
                    store.selectedConversationID = conversation.id
                    try? await Task.sleep(for: .milliseconds(12))
                }
            }),
            ("sidebar-collapse", { _ in
                withAnimation { columns.visibility = .detailOnly }
                try? await Task.sleep(for: .milliseconds(120))
            }),
            ("live-resize", { window in
                window.contentView?.viewWillStartLiveResize()
                window.setContentSize(.init(width: 780, height: 760))
                try? await Task.sleep(for: .milliseconds(60))
                window.setContentSize(.init(width: 1000, height: 760))
                window.contentView?.viewDidEndLiveResize()
                try? await Task.sleep(for: .milliseconds(60))
            }),
            ("app-hidden", { _ in
                NSApplication.shared.hide(nil)
                try? await Task.sleep(for: .milliseconds(300))
                NSApplication.shared.unhide(nil)
                try? await Task.sleep(for: .milliseconds(200))
            }),
            ("scrolled", { window in
                func scrollViews(_ view: NSView, into found: inout [NSScrollView]) {
                    if let scroll = view as? NSScrollView { found.append(scroll) }
                    for child in view.subviews { scrollViews(child, into: &found) }
                }
                var found: [NSScrollView] = []
                if let root = window.contentView { scrollViews(root, into: &found) }
                for scroll in found where scroll.documentView.map({ $0.bounds.height > 900 }) == true {
                    scroll.contentView.scroll(to: .init(x: 0, y: 200))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                try? await Task.sleep(for: .milliseconds(200))
            })
        ]

        var failures: [String] = []
        for (index, trigger) in triggers.enumerated() {
            columns.visibility = .all
            store.selectedConversationID = fixture.directA.id
            try await Task.sleep(for: .milliseconds(200))
            store.selectedConversationID = conversation.id
            // The reply lands while the conversation dissolve is still running.
            try await Task.sleep(for: .milliseconds(25))
            await trigger.1(window)
            let images = try (0..<2).map { offset in
                try fixture.repository.importAttachment(data: Self.png(seed: index * 2 + offset),
                    originalFilename: "frame-\(index)-\(offset).png", into: conversation.id, mediaType: "image/png")
            }
            try fixture.repository.append(ChatMessage(conversationID: conversation.id, author: .agent(fixture.a.id),
                body: Self.reply, delivery: .delivered, attachmentIDs: images.map(\.id)))
            store.refreshTranscripts()
            try await Task.sleep(for: .milliseconds(300))
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(700))
            if let missing = try await missingPhrases(window, label: trigger.0) { failures.append(missing) }
        }
        XCTAssertTrue(failures.isEmpty, "Message pixels were mirrored or lost:\n" + failures.joined(separator: "\n"))
    }

    private static func png(seed: Int) throws -> Data {
        let image = NSImage(size: .init(width: 240, height: 120))
        image.lockFocus()
        NSColor(calibratedHue: CGFloat(seed % 10) / 10, saturation: 0.6, brightness: 0.7, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 240, height: 120).fill()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return representation.representation(using: .png, properties: [:])!
    }

    private func missingPhrases(_ window: NSWindow, label: String) async throws -> String? {
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
        // The captured window is transparent; text recognition needs opaque pixels.
        let opaque = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        opaque.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        opaque.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        opaque.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let flattened = try XCTUnwrap(opaque.makeImage())
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: flattened).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let missing = Self.phrases.filter { !text.contains($0) }
        guard !missing.isEmpty else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("transcript-orientation-\(label).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, flattened, nil)
        CGImageDestinationFinalize(destination)
        return "[\(label)] missing \(missing) (frame at \(url.path)); recognized: \(text.replacingOccurrences(of: "\n", with: " / "))"
    }
}

@MainActor private final class ColumnModel: ObservableObject {
    @Published var visibility = NavigationSplitViewVisibility.all
}

private struct OrientationChat: View {
    let store: NoodleStore
    @ObservedObject var columns: ColumnModel
    @State private var preview = AttachmentPreviewController()

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns.visibility) {
            List(store.conversations, id: \.id, selection: $store.selectedConversationID) { conversation in
                Text(store.title(for: conversation)).tag(conversation.id)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
        } detail: {
            if let conversation = store.selectedConversation {
                ChatView(conversation: conversation, attachmentPreview: preview)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            let conversation = store.selectedConversation
            let background = store.background(for: conversation)
            ConversationWallpaper(background: background, imageURL: conversation.flatMap {
                store.repository.backgroundImageURL(background, conversationID: $0.id)
            })
            .overlay(alignment: .top) { ConversationWindowHeaderShade() }
            .ignoresSafeArea()
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .environment(store)
    }
}
