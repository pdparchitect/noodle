import AppKit
import QuartzCore
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
}
