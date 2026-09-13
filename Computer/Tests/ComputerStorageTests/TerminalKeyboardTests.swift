import AppKit
import SwiftTerm
import XCTest
@testable import NoodleComputer

@MainActor final class TerminalKeyboardTests: XCTestCase {
    private final class Capture: TerminalViewDelegate {
        var bytes: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
    }

    private func fixture() -> (ComputerNativeTerminalView, Capture, NSWindow) {
        _ = NSApplication.shared
        let view = ComputerNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let capture = Capture()
        view.terminalDelegate = capture
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, capture, window)
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }

    func testCommandKClearsOutputAndKeepsCurrentInputWithoutSendingGuestBytes() {
        let (view, capture, window) = fixture()
        defer { window.orderOut(nil) }
        view.feed(text: String(repeating: "old output\r\n", count: 100) + "prompt> unfinished command")
        let column = view.getTerminal().getCursorLocation().x
        XCTAssertTrue(view.canScroll)
        XCTAssertTrue(view.performKeyEquivalent(with: key("k", code: 40, modifiers: .command, in: window)))
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertFalse(text.contains("old output"))
        XCTAssertTrue(text.contains("prompt> unfinished command"))
        XCTAssertEqual(view.getTerminal().getCursorLocation().x, column)
        XCTAssertEqual(view.getTerminal().getCursorLocation().y, 0)
        XCTAssertFalse(view.canScroll)
        XCTAssertTrue(capture.bytes.isEmpty)
    }

    func testCommonShellKeysReachTheGuest() {
        let (view, capture, window) = fixture()
        defer { window.orderOut(nil) }
        let keys: [(String, UInt16, NSEvent.ModifierFlags, String)] = [
            ("c", 8, .control, "\u{03}"), ("d", 2, .control, "\u{04}"),
            ("l", 37, .control, "\u{0c}"), ("a", 0, .control, "\u{01}"),
            ("e", 14, .control, "\u{05}"), ("r", 15, .control, "\u{12}"),
            ("u", 32, .control, "\u{15}"), ("k", 40, .control, "\u{0b}"),
            ("w", 13, .control, "\u{17}"), ("\t", 48, [], "\t"),
            ("\r", 36, [], "\r"), ("\u{7f}", 51, [], "\u{7f}"),
            ("\u{f700}", 126, .function, "\u{1b}[A"),
            ("\u{f701}", 125, .function, "\u{1b}[B"),
            ("\u{f702}", 123, [.function, .option], "\u{1b}[1;3D"),
            ("\u{f703}", 124, [.function, .option], "\u{1b}[1;3C")
        ]
        for (characters, code, modifiers, expected) in keys {
            capture.bytes = []
            view.keyDown(with: key(characters, code: code, modifiers: modifiers, in: window))
            XCTAssertEqual(capture.bytes, Array(expected.utf8), "Key code \(code), modifiers \(modifiers.rawValue)")
        }
    }

    func testClearPreservesWrappedInputAndTerminalModes() {
        let (view, capture, window) = fixture()
        defer { window.orderOut(nil) }
        view.resize(cols: 20, rows: 8)
        view.feed(text: "old output\r\n\u{1b}[?2004h\u{1b}[?1h\u{1b}[32mprompt> a long command spanning rows")
        let terminal = view.getTerminal()
        let x = terminal.buffer.x
        let y = terminal.buffer.y
        let lines = (1...y).map { BufferLine(from: terminal.getLine(row: $0)!) }
        view.clearTerminal(nil)
        XCTAssertEqual(terminal.buffer.x, x)
        XCTAssertEqual(terminal.buffer.y, y - 1)
        XCTAssertTrue(terminal.bracketedPasteMode)
        XCTAssertTrue(terminal.applicationCursor)
        for (row, line) in lines.enumerated() {
            XCTAssertEqual(terminal.getLine(row: row)?.translateToString(), line.translateToString())
            XCTAssertEqual(terminal.getLine(row: row)?.getData().map(\.attribute), line.getData().map(\.attribute))
        }
        view.clearTerminal(nil)
        XCTAssertEqual(terminal.buffer.y, y - 1, "Clearing twice must not remove a wrapped prompt")
        XCTAssertTrue(capture.bytes.isEmpty)
    }

    func testClearLeavesAlternateScreenApplicationIntact() {
        let (view, capture, window) = fixture()
        defer { window.orderOut(nil) }
        view.feed(text: String(repeating: "old output\r\n", count: 100))
        view.feed(text: "\u{1b}[?1049h\u{1b}[?2004h\u{1b}[4;5Heditor contents")
        let terminal = view.getTerminal()
        let before = terminal.getBufferAsData()
        let cursor = terminal.getCursorLocation()
        view.clearTerminal(nil)
        XCTAssertTrue(terminal.isCurrentBufferAlternate)
        XCTAssertTrue(terminal.bracketedPasteMode)
        XCTAssertEqual(terminal.getBufferAsData(), before)
        XCTAssertEqual(terminal.buffer.x, cursor.x)
        XCTAssertEqual(terminal.buffer.y, cursor.y)
        XCTAssertTrue(capture.bytes.isEmpty)
        view.feed(text: "\u{1b}[?1049l")
        XCTAssertFalse(view.canScroll)
    }

    func testClearDoesNotInterruptPartialGuestEscapeSequence() {
        let (view, capture, window) = fixture()
        defer { window.orderOut(nil) }
        view.feed(text: "old output\r\nprompt> \u{1b}[3")
        view.clearTerminal(nil)
        view.feed(text: "1mcontinued")
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(text.contains("prompt> continued"))
        XCTAssertFalse(text.contains("1m"))
        XCTAssertTrue(capture.bytes.isEmpty)
    }

    func testClearShortcutOnlyHandlesCommandKInTheFocusedTerminal() {
        let (view, _, window) = fixture()
        defer { window.orderOut(nil) }
        view.feed(text: "keep this\r\nprompt> ")
        let before = view.getTerminal().getBufferAsData()
        for modifiers: NSEvent.ModifierFlags in [.control, [.command, .shift], [.command, .option]] {
            XCTAssertFalse(view.performKeyEquivalent(with: key("k", code: 40, modifiers: modifiers, in: window)))
        }
        window.makeFirstResponder(nil)
        XCTAssertFalse(view.performKeyEquivalent(with: key("k", code: 40, modifiers: .command, in: window)))
        XCTAssertEqual(view.getTerminal().getBufferAsData(), before)
    }

    func testContextMenuExposesClearTerminal() throws {
        let (view, _, window) = fixture()
        defer { window.orderOut(nil) }
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        let item = try XCTUnwrap(view.menu(for: event)?.items.first { $0.title == "Clear Terminal" })
        XCTAssertEqual(item.keyEquivalent, "k")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertTrue(item.target === view)
        XCTAssertTrue(view.validateUserInterfaceItem(item))
    }
}
