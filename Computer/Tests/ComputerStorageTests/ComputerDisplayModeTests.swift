import AppKit
import ComputerCore
import XCTest
@testable import NoodleComputer

final class ComputerDisplayModeTests: XCTestCase {
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
