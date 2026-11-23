import AppKit
import QuartzCore
import NoodleWallpaper
import SwiftUI
import XCTest
@testable import Noodle

@MainActor final class ConversationTransitionTests: XCTestCase {
    func testOnlyConversationChangesDissolveAndRapidSwitchesKeepOneAnimation() {
        let id = UUID()
        let surface = ConversationTransitionSurface(content: AnyView(Text("First")), conversationID: id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = surface
        surface.layoutSubtreeIfNeeded()
        XCTAssertNil(surface.subviews.first { $0 is NSHostingView<AnyView> },
            "The transcript's hosting view must be the surface itself: a wrapper around it adds a coordinate flip between SwiftUI and the text layers it draws")
        XCTAssertTrue(surface.isFlipped, "The transition must keep SwiftUI's top-left coordinate system")
        XCTAssertNil(surface.layer?.animationKeys())

        surface.update(content: AnyView(Text("New message")), conversationID: id, reduceMotion: false)
        XCTAssertNil(surface.layer?.animationKeys(), "Incoming messages must not restart the transition")
        for index in 0..<40 {
            let next = UUID()
            surface.update(content: AnyView(Text("Conversation \(index)")), conversationID: next, reduceMotion: false)
            XCTAssertEqual(surface.conversationID, next)
            XCTAssertEqual(surface.layer?.animationKeys(), [ConversationTransitionSurface.animationKey])
            let transition = surface.layer?.animation(forKey: ConversationTransitionSurface.animationKey) as? CATransition
            XCTAssertEqual(transition?.type, .fade)
            XCTAssertEqual(surface.alphaValue, 1, "The conversation surface must never fade to blank")
        }
        window.contentView = nil
        XCTAssertNil(surface.layer?.animationKeys(), "Detaching must cancel the transition")
    }

    func testReduceMotionCancelsAnActiveDissolveAndKeepsNavigationImmediate() {
        let surface = ConversationTransitionSurface(content: AnyView(Text("First")), conversationID: UUID())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = surface
        surface.update(content: AnyView(Text("Second")), conversationID: UUID(), reduceMotion: false)
        XCTAssertNotNil(surface.layer?.animationKeys())
        let finalID = UUID()
        surface.update(content: AnyView(Text("Final")), conversationID: finalID, reduceMotion: true)
        XCTAssertEqual(surface.conversationID, finalID)
        XCTAssertNil(surface.layer?.animationKeys())
    }

    /// The conversation's colour scheme can still say light when its background has turned the window dark. In light
    /// mode, Use as Background's closing sheet resets the window's appearance a moment after the background darkened
    /// it, and SwiftUI's colour scheme follows the window's appearance late, so the transcript kept light colours
    /// until the conversation was selected again. In front of a background it takes dark colours from the background.
    func testTranscriptIsDarkInFrontOfABackgroundWhateverColoursTheWindowLastGaveIt() async {
        let seen = SeenColorScheme(), state = BackgroundState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        // The light colours the conversation still has from its window.
        window.contentView = NSHostingView(rootView: ConversationWithBackground(state: state, seen: seen)
            .environment(\.colorScheme, .light))
        window.orderFront(nil)
        await settle(window)
        XCTAssertEqual(seen.scheme, .light)

        for background in [ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).metal", mediaKind: .shader),
                           ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).mp4", mediaKind: .video),
                           ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).jpg", mediaKind: .image),
                           ConversationBackground(preset: .midnight)] {
            state.background = background
            await settle(window)
            XCTAssertEqual(seen.scheme, .dark, "The transcript kept light colours in front of \(background.imageFilename ?? "a preset")")
        }

        state.background = ConversationBackground()
        await settle(window)
        XCTAssertEqual(seen.scheme, .light, "Without a background the conversation keeps its own colours")
    }

    private func settle(_ window: NSWindow) async {
        for _ in 0..<5 {
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

@MainActor private final class SeenColorScheme { var scheme: ColorScheme? }

@MainActor private final class BackgroundState: ObservableObject {
    @Published var background = ConversationBackground()
}

/// A conversation as the window shows it: its transcript, with its background behind it.
private struct ConversationWithBackground: View {
    @ObservedObject var state: BackgroundState
    let seen: SeenColorScheme
    let conversationID = UUID()

    var body: some View {
        ConversationTransition(conversationID: conversationID) { ColorSchemeReader(seen: seen) }
            .colorScheme(over: state.background)
            .frame(width: 600, height: 400)
            .background { ConversationWallpaper(background: state.background) }
    }
}

private struct ColorSchemeReader: View {
    let seen: SeenColorScheme
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let _ = { seen.scheme = colorScheme }()
        Text("Transcript")
    }
}
