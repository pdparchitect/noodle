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

    /// Website data counts with the data folder; WebKit's own salts and empty folders do not.
    @MainActor func testUsageCountsWebsiteDataAndSkipsNoodletsWithNothingSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "StorageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        func write(_ path: String, _ count: Int) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: count).write(to: file)
        }
        let (web, salted, tested) = (UUID(), UUID(), UUID())
        defaults.set(web.uuidString, forKey: "store.web.user")
        defaults.set(tested.uuidString, forKey: "store.web.test")
        defaults.set(salted.uuidString, forKey: "store.salted.user")
        try write("Data/files/notes.txt", 3)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Data/empty/User"), withIntermediateDirectories: true)
        let stores = "WebKit/WebsiteDataStore/"
        try write(stores + "\(web.uuidString.lowercased())/Origins/salt", 8)
        try write(stores + "\(web.uuidString.lowercased())/Origins/a/a/LocalStorage/localstorage.sqlite3", 7)
        try write(stores + "\(tested.uuidString.lowercased())/Cookies/Cookies.binarycookies", 5)
        try write(stores + "\(tested.uuidString.lowercased())/ResourceLoadStatistics/observations.db", 9)
        try write(stores + "\(salted.uuidString.lowercased())/Origins/salt", 8)

        let usage = AppletStorageUsage()
        await usage.refresh(
            root: root, defaults: defaults, websiteData: root.appendingPathComponent(stores)).value
        XCTAssertEqual(usage.sizes, ["files": 3, "web": 12])

        // Where WebKit's folder cannot be found, noodlets with stores stay listed to be removed.
        await usage.refresh(root: root, defaults: defaults, websiteData: nil).value
        XCTAssertEqual(usage.sizes, ["files": 3, "web": 0, "salted": 0])
    }
}
