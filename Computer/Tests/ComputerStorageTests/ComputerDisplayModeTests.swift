import AppKit
import ComputerCore
import XCTest
@testable import NoodleComputer

final class ComputerDisplayModeTests: XCTestCase {
    @MainActor func testWindowsUsesOnlyTheGuestPointerInsideItsDisplayedFrame() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("Windows requires macOS 27") }
        let computer = WindowsComputer(computer: Computer(name: "Test", kind: .windows), directory: URL(fileURLWithPath: "/unused"))
        let view = CursorRecordingWindowsView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.attach(computer)
        view.resetCursorRects()
        XCTAssertTrue(view.cursors.isEmpty, "Keep the Mac pointer while there is no guest image")
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
            bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        computer.onFrame?(try XCTUnwrap(context.makeImage()))
        view.resetCursorRects()
        XCTAssertEqual(view.cursors.count, 1, "The frame already contains Windows' pointer; suppress the second pointer")
        if let (rect, cursor) = view.cursors.first {
            XCTAssertEqual(rect, NSRect(x: 0, y: 25, width: 100, height: 50), "Keep the Mac pointer in the letterbox margins")
            XCTAssertEqual(cursor.image.size, NSSize(width: 1, height: 1))
            XCTAssertFalse(cursor === NSCursor.arrow)
        }
        view.cursors = []
        view.setFrameSize(NSSize(width: 200, height: 100))
        view.resetCursorRects()
        XCTAssertEqual(view.cursors.first?.0, NSRect(x: 0, y: 0, width: 200, height: 100))
        let next = WindowsComputer(computer: Computer(name: "Next", kind: .windows), directory: URL(fileURLWithPath: "/unused"))
        view.cursors = []
        view.attach(next)
        view.resetCursorRects()
        XCTAssertTrue(view.cursors.isEmpty, "A replacement VM without a frame must restore the Mac pointer")
        XCTAssertNil(view.layer?.contents, "Do not leave the previous VM's image visible")
    }

    @MainActor func testDesktopCanSelectAnyViewWithoutReplacingSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let session = ComputerSession(Computer(name: "Desktop", kind: .container, imageReference: Computer.desktopImage))
        let runtime = ContainerComputer()
        let terminal = GuestTerminal()
        session.container = runtime; session.terminal = terminal; session.phase = .running
        let files = session.filesModel(for: runtime)
        files.folder = "/workspace/Documents"
        XCTAssertEqual(session.availableDisplayModes, [.desktop, .terminal, .files])
        XCTAssertEqual(session.displayMode, .desktop)
        // Exercise Files → Terminal directly, plus reselecting the active segment.
        for mode: ComputerDisplayMode in [.files, .terminal, .terminal, .desktop, .terminal, .files, .desktop] {
            await store.selectDisplay(mode, in: session)
            XCTAssertEqual(session.displayMode, mode)
        }
        XCTAssertTrue(session.terminal === terminal)
        XCTAssertTrue(session.container === runtime)
        XCTAssertTrue(session.filesModel(for: runtime) === files)
        XCTAssertEqual(files.folder, "/workspace/Documents")
    }

    @MainActor func testShellOffersOnlyAvailableModesAndIgnoresUnavailableTransitions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let session = ComputerSession(Computer(name: "Shell", kind: .container))
        session.container = ContainerComputer()
        XCTAssertEqual(session.availableDisplayModes, [.terminal, .files])
        await store.selectDisplay(.files, in: session)
        XCTAssertEqual(session.displayMode, .terminal) // Stopped.
        session.phase = .running
        await store.selectDisplay(.files, in: session)
        XCTAssertEqual(session.displayMode, .files)
        await store.selectDisplay(.desktop, in: session)
        XCTAssertEqual(session.displayMode, .files)
        session.openingTerminal = true
        await store.selectDisplay(.terminal, in: session)
        XCTAssertEqual(session.displayMode, .files)
        session.openingTerminal = false
        await store.selectDisplay(.terminal, in: session)
        XCTAssertEqual(session.displayMode, .terminal)
    }
}

@available(macOS 27, *)
@MainActor private final class CursorRecordingWindowsView: WindowsScreenView {
    var cursors: [(NSRect, NSCursor)] = []
    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) { cursors.append((rect, cursor)) }
}
