#if DEBUG
import Foundation
import XCTest
@testable import NoodleComputer

final class WindowsNeptuneSetupTests: XCTestCase {
    @MainActor func testPowerCycleDoesNotFinishEitherVMFromItsIntermediateStop() async throws {
        let first = WindowsPowerCycle(), second = WindowsPowerCycle()
        var finished = false, started = false
        try await first.run(stop: {
            finished = first.handlesGuestStop(machineStopped: true)
            XCTAssertTrue(second.handlesGuestStop(machineStopped: true))
        }, start: { started = true })
        XCTAssertFalse(finished)
        XCTAssertTrue(started)
        XCTAssertFalse(first.handlesGuestStop(machineStopped: false))
        XCTAssertTrue(first.handlesGuestStop(machineStopped: true))
    }

    @MainActor func testStartupVerifiesTheDriverAfterOneRestart() async throws {
        let startup = WindowsGraphicsStartup()
        var installed = false
        let first = try await startup.check { mayStage in
            XCTAssertTrue(mayStage)
            installed = true
            return true
        }
        XCTAssertTrue(installed)
        XCTAssertEqual(first, .restart)
        let second = try await startup.check { mayStage in
            XCTAssertFalse(mayStage, "A failed installation must not loop forever")
            return false
        }
        XCTAssertEqual(second, .ready)
        let other = WindowsGraphicsStartup()
        let independent = try await other.check { mayStage in
            XCTAssertTrue(mayStage, "Each VM owns its installation state")
            return true
        }
        XCTAssertEqual(independent, .restart)
    }

    func testAWorking3DDriverIsLeftAlone() async throws {
        var calls = 0
        let restart = try await WindowsNeptuneSetup.prepare(resources: URL(fileURLWithPath: "/unused"), run: { _ in
            calls += 1
            return ("", 0)
        }, upload: { _, _ in XCTFail("A working driver must not be uploaded again") })
        XCTAssertFalse(restart)
        XCTAssertEqual(calls, 1)
    }

    func testTheActiveDriverIsNeverReplacedWhileStaging3D() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("neptune-guest"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("neptune-guest/viogpu3d.inf"))
        var commands: [String] = [], uploads: [String] = []
        let restart = try await WindowsNeptuneSetup.prepare(resources: root, run: { command in
            commands.append(command)
            return ("", commands.count == 1 ? 10 : 0)
        }, upload: { _, path in uploads.append(path) })
        XCTAssertTrue(restart)
        XCTAssertTrue(uploads.contains("/C/noodle/3d/viogpu3d.inf"))
        XCTAssertTrue(commands.contains { $0.contains("pnputil /add-driver") })
        XCTAssertFalse(commands.contains { $0.contains("/install") || $0.contains("/delete-driver") || $0.contains("/uninstall") })
    }

    func testAnUnexpectedDriverQueryFailureDoesNotInstallAnything() async {
        var calls = 0
        do {
            _ = try await WindowsNeptuneSetup.prepare(resources: URL(fileURLWithPath: "/unused"), run: { _ in
                calls += 1
                return ("query failed", 1)
            }, upload: { _, _ in XCTFail("Failed queries must not change Windows") })
            XCTFail("The failure must be reported")
        } catch {}
        XCTAssertEqual(calls, 1)
    }

    func testStagingFailureDoesNotRequestReenumeration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("neptune-guest"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("neptune-guest/viogpu3d.inf"))
        var calls = 0
        do {
            _ = try await WindowsNeptuneSetup.prepare(resources: root, run: { _ in
                calls += 1
                return ("", calls == 1 ? 10 : (calls == 3 ? 1 : 0))
            }, upload: { _, _ in })
            XCTFail("A rejected package must not request a reboot")
        } catch {}
        XCTAssertEqual(calls, 3, "Do not schedule a device reinstall after pnputil rejects the package")
    }
}
#endif
