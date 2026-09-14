import ComputerBridge
import ComputerCore
import XCTest
@testable import NoodleComputer

@MainActor final class LocalMacLibraryTests: XCTestCase {
    func testCreatingLocalMacOnlyCreatesALibraryRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let computer = Computer(name: "Retained Mac", kind: .localMac)
        let created = await store.create(computer, source: nil)
        XCTAssertTrue(created)
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertNil(session.localMac)
        XCTAssertNil(session.computer.localMacSetupRequested)
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertEqual(session.availableDisplayModes, [.desktop, .terminal, .files])
        XCTAssertEqual(session.displayMode, .desktop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.library.directory(for: computer.id).appendingPathComponent("Disk.img").path))
        XCTAssertEqual(try store.library.load().first?.kind, .localMac)
        let reference = ComputerReference(computer: .init(id: computer.id, name: computer.name, kind: "Local Mac", state: "Stopped", symbol: "person.crop.rectangle"), terminalPreview: "", view: "web")
        XCTAssertTrue(try store.selectComputer(reference) === session)
        XCTAssertEqual(session.phase, .stopped)
    }
}
