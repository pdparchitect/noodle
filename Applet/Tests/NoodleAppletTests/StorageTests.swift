import XCTest

@testable import NoodleApplet

final class StorageTests: XCTestCase {
    /// Launch can clear a gone noodlet's website data before anything else has used WebKit.
    /// Only a process that has not touched WebKit shows it, so the removal runs in a fresh one.
    func testRemovingWebsiteDataFirstThingInAProcessDoesNotCrash() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest", "NoodleAppletTests.StorageTests/testRemoveWebsiteDataInFreshProcess",
                             Bundle(for: Self.self).bundlePath]
        process.environment = ProcessInfo.processInfo.environment.merging(["APPLET_STORAGE_CHILD": "1"]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
    }

    @MainActor func testRemoveWebsiteDataInFreshProcess() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["APPLET_STORAGE_CHILD"] == "1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "StorageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(UUID().uuidString, forKey: "store.gone.user")
        await AppletStorage.remove("gone", root: root, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "store.gone.user"))
    }

    /// Settings shows the last sizes at once and measures again in the background.
    @MainActor func testUsageKeepsTheLastSizesWhileMeasuringAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func save(_ key: String, _ count: Int) throws {
            let folder = root.appendingPathComponent("Data/\(key)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: count).write(to: folder.appendingPathComponent("file"))
        }
        try save("a", 3)
        let usage = AppletStorageUsage()
        XCTAssertNil(usage.sizes)
        await usage.refresh(root: root).value
        XCTAssertEqual(usage.sizes, ["a": 3])

        try save("b", 5)
        let measuring = usage.refresh(root: root)
        XCTAssertEqual(usage.sizes, ["a": 3])
        await measuring.value
        XCTAssertEqual(usage.sizes, ["a": 3, "b": 5])
    }
}
