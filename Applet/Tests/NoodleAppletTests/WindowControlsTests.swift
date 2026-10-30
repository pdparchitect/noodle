import AppKit
import AppletCore
import ObjectiveC
import WebKit
import XCTest

@testable import NoodleApplet

/// A noodlet that draws its own title bar hides the native buttons and acts through noodle.window.
final class WindowControlsTests: XCTestCase {
    @MainActor private func window(titlebar: String, extra: String = "") throws -> NSWindow {
        let options = try JSONDecoder().decode(
            NoodletWindowOptions.self, from: Data(#"{"titlebar":\#(titlebar)\#(extra)}"#.utf8))
        let window = WindowPresentation.make(options, size: options.size())
        WindowPresentation.apply(options, to: window, content: NSView(), size: options.size(), key: "", remember: false)
        return window
    }


    /// A real mouse hit must reach WebKit before its HTML no-drag exclusions can work.
    @MainActor func testCustomTitlebarDoesNotCoverPageControls() throws {
        for extra in ["", #","background":"translucent","cornerRadius":18"#, #","type":"preview""#] {
            let options = try JSONDecoder().decode(NoodletWindowOptions.self,
                from: Data(#"{"titlebar":"none"\#(extra)}"#.utf8))
            let size = options.size()
            let page = NSView(frame: CGRect(origin: .zero, size: size))
            let window = WindowPresentation.make(options, size: size)
            defer { window.close() }
            WindowPresentation.apply(options, to: window, content: page, size: size, key: "", remember: false)
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            // Custom controls at CSS y=9...34, plus the rest of the title bar.
            for x in [20.0, 100.0, 200.0] {
                let point = CGPoint(x: x, y: root.bounds.height - 20)
                XCTAssertTrue(root.hitTest(point) === page, "native view intercepted page at \(point), \(extra)")
            }
        }
    }

    @MainActor func testHiddenNativeTitlebarStillHasADragStrip() throws {
        let window = try window(titlebar: "false")
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let hit = try XCTUnwrap(root.hitTest(CGPoint(x: 150, y: root.bounds.height - 15)))
        XCTAssertTrue(hit.mouseDownCanMoveWindow)
        XCTAssertFalse(hit === root)
    }

    @MainActor private func buttons(_ window: NSWindow) -> [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    @MainActor func testNoTitlebarHidesTheNativeButtonsButKeepsTheirActions() throws {
        let window = try window(titlebar: #""none""#)
        XCTAssertEqual(buttons(window).count, 3)
        XCTAssertTrue(buttons(window).allSatisfy(\.isHidden))
        XCTAssertTrue(window.styleMask.isSuperset(of: [.closable, .miniaturizable, .resizable]))
        XCTAssertEqual(window.titleVisibility, .hidden)
    }

    @MainActor func testAHiddenTitlebarKeepsTheNativeButtons() throws {
        let window = try window(titlebar: "false")
        XCTAssertEqual(buttons(window).count, 3)
        XCTAssertFalse(buttons(window).contains(where: \.isHidden))
    }

    @MainActor func testWindowActionsOnlyActOnScreen() throws {
        let window = try window(titlebar: #""none""#)
        for action in ["close", "minimize", "zoom", "toggleFullScreen"] {
            XCTAssertFalse(try WindowPresentation.perform(action, on: window), action)
        }
        XCTAssertThrowsError(try WindowPresentation.perform("maximize", on: window))
    }

    /// macOS rounds only titled windows, so a set radius drops the title bar and shapes the content.
    @MainActor func testSquareCornersDropTheTitleBarButKeepFocusAndActions() throws {
        let window = try window(titlebar: #""none""#, extra: #","cornerRadius":0"#)
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.isSuperset(of: [.closable, .miniaturizable, .resizable]))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
        XCTAssertTrue(window.isOpaque)
    }

    @MainActor func testARoundedRadiusClipsTheContent() throws {
        let window = try window(titlebar: #""none""#, extra: #","cornerRadius":12"#)
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        let layer = try XCTUnwrap(window.contentView?.layer)
        XCTAssertEqual(layer.cornerRadius, 12)
        XCTAssertTrue(layer.masksToBounds)
    }

    @MainActor func testARoundedTranslucentWindowMasksItsMaterial() throws {
        let window = try window(titlebar: #""none""#, extra: #","cornerRadius":12,"background":"translucent""#)
        let effect = try XCTUnwrap(window.contentView?.subviews.first as? NSVisualEffectView)
        XCTAssertNotNil(effect.maskImage)
    }

    /// WebKit hands a key the page did not cancel back up to the window, where AppKit beeps. A game
    /// reading the arrow keys without preventDefault beeped on every press; the page had the key.
    @MainActor func testKeysAPageLeftUnhandledDoNotBeep() throws {
        let original = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.noResponder(for:))))
        let recording = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.recordingNoResponder(for:))))
        method_exchangeImplementations(original, recording)
        defer { method_exchangeImplementations(original, recording) }
        let keyDown = #selector(NSResponder.keyDown(with:))
        for extra in ["", #","cornerRadius":12"#, #","type":"preview""#] {
            let window = try window(titlebar: "true", extra: extra)
            let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let field = NSTextView()
            window.contentView?.addSubview(page)
            window.contentView?.addSubview(field)
            unhandledKeys = 0
            XCTAssertTrue(window.makeFirstResponder(page), extra)
            window.noResponder(for: keyDown)
            XCTAssertEqual(unhandledKeys, 0, "a key the page had beeped\(extra)")

            // Anything else in the window still says when nothing took a key.
            XCTAssertTrue(window.makeFirstResponder(field), extra)
            window.noResponder(for: keyDown)
            XCTAssertEqual(unhandledKeys, 1, extra)
        }
    }
}

extension WindowControlsTests {
    /// Escape the page did not cancel comes back up as a cancel command, which AppKit answers with
    /// a beep of its own; a game paused with Escape beeped every time. The page had that key too.
    @MainActor func testCommandsAPageLeftUnhandledDoNotBeep() throws {
        let original = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.doCommand(by:))))
        let recording = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.recordingDoCommand(by:))))
        method_exchangeImplementations(original, recording)
        defer { method_exchangeImplementations(original, recording) }
        let cancel = #selector(NSResponder.cancelOperation(_:))
        for extra in ["", #","cornerRadius":12"#, #","type":"preview""#] {
            let window = try window(titlebar: "true", extra: extra)
            let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let field = NSTextView()
            window.contentView?.addSubview(page)
            window.contentView?.addSubview(field)
            unhandledCommands = 0
            XCTAssertTrue(window.makeFirstResponder(page), extra)
            window.doCommand(by: cancel)
            XCTAssertEqual(unhandledCommands, 0, "a command the page had beeped\(extra)")

            XCTAssertTrue(window.makeFirstResponder(field), extra)
            window.doCommand(by: cancel)
            XCTAssertEqual(unhandledCommands, 1, extra)
        }
    }
}

@MainActor private var unhandledCommands = 0
@MainActor private var unhandledKeys = 0
extension NSResponder {
    /// Stands in for AppKit's handling, and its beep, of a command nothing took.
    @MainActor @objc fileprivate func recordingDoCommand(by selector: Selector) { unhandledCommands += 1 }

    /// Stands in for AppKit's beep while the test runs.
    @MainActor @objc fileprivate func recordingNoResponder(for selector: Selector) {
        if selector == #selector(NSResponder.keyDown(with:)) { unhandledKeys += 1 }
    }
}
