#if NOODLE_DEV_HOOKS
import Foundation
import NoodleCore
import NoodleScenarios
import XCTest

/// Every scenario under `Scenarios/` read, checked and seeded into a workspace, wherever the apps that play them build.
/// The Mac's own tests also play them; this is what Noodle for Windows can rely on from the same files.
final class ScenariosTests: XCTestCase {
    private static let scenariosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scenarios", isDirectory: true)
    private var directories: [URL] = []
    #if canImport(AVFoundation)
    private static let keepsPictureBackgrounds = true
    #else
    private static let keepsPictureBackgrounds = false
    #endif

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scenarios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    /// Scenarios whose media scripts/scenario.sh has not fetched are sound but cannot be read here, so they are left out.
    private func listings() -> [ScenarioListing] {
        ScenarioListing.all(in: Self.scenariosRoot) { folder in
            (try Scenario.load(from: folder, preferenceKeys: nil, settingsTabs: nil).title, nil)
        }
    }

    private func loadable() -> [(name: String, scenario: Scenario)] {
        listings().compactMap { listing in
            guard listing.error == nil,
                  let scenario = try? Scenario.load(from: listing.folder, preferenceKeys: nil, settingsTabs: nil) else { return nil }
            return (listing.name, scenario)
        }
    }

    func testEveryScenarioLoads() throws {
        let all = listings()
        XCTAssertFalse(all.isEmpty, "No scenarios under \(Self.scenariosRoot.path)")
        for listing in all where !listing.needsFetch {
            XCTAssertNil(listing.error, "\(listing.name): \(listing.error ?? "")")
        }
    }

    func testEveryScenarioSeedsAWorkspace() throws {
        let scenarios = loadable()
        XCTAssertFalse(scenarios.isEmpty)
        for (name, scenario) in scenarios {
            let root = try temporaryDirectory()
            let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Workspace", isDirectory: true))
            var seeded = Scenario.Seeded(clock: try ScenarioTime.start(scenario.clock, now: Date()),
                                         discovery: HarnessDiscovery(homeDirectory: root, executableSearchDirectories: [], environment: [:]))
            do {
                try scenario.seedStore(into: repository, seeded: &seeded)
                try scenario.applyOverlay(to: repository)
            } catch ConversationBackgroundError.invalidImage where !Self.keepsPictureBackgrounds {
                // NoodleCore keeps a picture background only where it can redraw it as a JPEG; elsewhere, so far, only
                // presets. Such a scenario is not yet one Windows can show, which the parity list says, not a broken scenario.
                print("\(name): not seeded here, as its picture background needs a platform that redraws pictures")
                continue
            } catch {
                XCTFail("\(name): \(error.localizedDescription)")
                continue
            }
            XCTAssertEqual(seeded.agents.count, scenario.agents.count, name)
            XCTAssertEqual(Set(seeded.conversations.keys), Set((scenario.conversations ?? []).map(\.key)), name)
            let messages = (scenario.conversations ?? []).reduce(0) { $0 + ($1.messages?.count ?? 0) }
            let saved = try seeded.conversations.values.reduce(0) { $0 + (try repository.loadMessages(conversationID: $1.id).count) }
            XCTAssertEqual(saved, messages, name)
        }
    }

    func testClockTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let clock = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 10)))
        XCTAssertEqual(try ScenarioTime.date("09:41", clock: clock, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 9, minute: 41)))
        XCTAssertEqual(try ScenarioTime.date("-2d 08:00", clock: clock, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 8)))
        XCTAssertEqual(try ScenarioTime.date("-15m", clock: clock, calendar: calendar), clock.addingTimeInterval(-15 * 60))
        XCTAssertThrowsError(try ScenarioTime.start("-1h", now: clock, calendar: calendar))
        XCTAssertThrowsError(try ScenarioTime.date("9:41", clock: clock, calendar: calendar))
    }

    func testAnUnknownKeyIsAnError() throws {
        let folder = try temporaryDirectory().appendingPathComponent("typo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{ "version": 1, "title": "Typo", "clok": "10:00", "harnesses": {}, "agents": [] }"#.utf8)
            .write(to: folder.appendingPathComponent("scenario.json"))
        XCTAssertThrowsError(try Scenario.load(from: folder, preferenceKeys: nil, settingsTabs: nil)) {
            XCTAssertEqual(($0 as? ScenarioError)?.errorDescription, "Unknown keys in scenario.json: clok")
        }
    }

    func testCacheNamesMatchTheScript() {
        XCTAssertEqual(ScenarioSupport.cacheStem(for: "https://www.pexels.com/download/video/854261/"), "1b4292543e292d4e")
    }
}
#endif
