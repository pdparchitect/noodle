import Foundation
import XCTest
@testable import NoodleRuntime
@testable import NoodleRuntimeSettings

final class StorageUsageTests: XCTestCase {
    func testMeasureSortsFoldersIntoKindsAndBots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support")
        let data = support.appendingPathComponent("Noodle")
        let bot = UUID()
        func write(_ path: String, bytes: Int, in base: URL = data) throws {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        try write("Agents/\(bot.uuidString)/workspace/big.bin", bytes: 300_000)
        try write("Conversations/a/messages.json", bytes: 100_000)
        try write("usage.sqlite", bytes: 50_000)
        try write("spaces.json", bytes: 10)
        // A login's home holds what its harness keeps there, such as Codex's plugins, not only the credentials.
        try write("HarnessProfiles/\(UUID().uuidString)/home/.codex/plugins/plugin.bin", bytes: 40_000)
        try write("Caches/thing", bytes: 20_000, in: root.appendingPathComponent("Library"))
        try write("This Mac Hub/hub.key", bytes: 10, in: support)

        let snapshot = StorageSnapshot.measure(dataRoot: data, applicationSupport: support,
                                               library: root.appendingPathComponent("Library"))

        XCTAssertGreaterThanOrEqual(snapshot.kinds[.bots] ?? 0, 300_000)
        XCTAssertEqual(snapshot.bots[bot], snapshot.kinds[.bots])
        XCTAssertGreaterThanOrEqual(snapshot.kinds[.conversations] ?? 0, 100_000)
        XCTAssertGreaterThanOrEqual(snapshot.kinds[.usage] ?? 0, 50_000)
        XCTAssertGreaterThanOrEqual(snapshot.kinds[.caches] ?? 0, 20_000)
        XCTAssertGreaterThan(snapshot.kinds[.hubs] ?? 0, 0)
        XCTAssertGreaterThan(snapshot.kinds[.other] ?? 0, 0)
        XCTAssertNil(snapshot.kinds[.harnesses])
        XCTAssertGreaterThanOrEqual(snapshot.kinds[.logins] ?? 0, 40_000)
        XCTAssertEqual(StorageSnapshot.Kind.logins.rawValue, "Logins")
    }

    @MainActor func testRefreshKeepsTheLastSnapshotUntilTheNewOneLands() async throws {
        let gate = DispatchSemaphore(value: 0)
        let count = Counter()
        let storage = StorageUsage {
            let n = count.next()
            if n > 1 { gate.wait() }
            return StorageSnapshot(kinds: [.bots: Int64(n)], bots: [:], date: Date())
        }
        storage.refresh()
        try await wait { storage.snapshot?.kinds[.bots] == 1 }

        storage.refresh()
        XCTAssertTrue(storage.isMeasuring)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(storage.snapshot?.kinds[.bots], 1)
        gate.signal()
        try await wait { storage.snapshot?.kinds[.bots] == 2 }
        XCTAssertFalse(storage.isMeasuring)
    }

    func testBotGroupingNamesBotsAndFoldsRemovedOnes() {
        let alfred = UUID(), gone = UUID(), alsoGone = UUID()
        let snapshot = StorageSnapshot(kinds: [.bots: 600, .caches: 5], bots: [alfred: 400, gone: 150, alsoGone: 50], date: Date())

        let bots = StorageReport(snapshot: snapshot, grouping: .bot, bots: [alfred: "Alfred"])
        XCTAssertEqual(bots.rows.map(\.group), ["Alfred", StorageReport.removedBots])
        XCTAssertEqual(bots.rows.map(\.bytes), [400, 200])
        XCTAssertEqual(bots.share(of: bots.rows[0]), 400.0 / 600.0)

        let kinds = StorageReport(snapshot: snapshot, grouping: .kind, bots: [:])
        XCTAssertEqual(kinds.rows.map(\.group), ["Bots", "Caches"])
        XCTAssertEqual(kinds.total, 605)
    }

    func testSlicesPastTheColorsFoldIntoOther() {
        var bots: [UUID: Int64] = [:], names: [UUID: String] = [:]
        for index in 0..<9 {
            let id = UUID()
            bots[id] = Int64(100 - index)
            names[id] = "Bot \(index)"
        }
        let report = StorageReport(snapshot: StorageSnapshot(kinds: [:], bots: bots, date: Date()), grouping: .bot, bots: names)
        XCTAssertEqual(report.slices.count, UsageReport.colorCount + 1)
        XCTAssertEqual(report.slices.last?.group, UsageReport.otherGroup)
        XCTAssertEqual(report.slices.last?.bytes, 92 + 93)
        XCTAssertEqual(report.slices.reduce(0) { $0 + $1.bytes }, report.total)
    }

    @MainActor private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition not met", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
