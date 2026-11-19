import Foundation
@testable import PionCore
import XCTest

final class AlertWatchTests: XCTestCase {
    private let account = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func alert(_ id: String, _ minutes: Double) -> ServiceAlert {
        ServiceAlert(id: id, time: start.addingTimeInterval(minutes * 60))
    }

    func testAnAccountFirstWatchedStartsFromNowSoItsPastIsNotNew() async throws {
        var watch = AlertWatch()
        var asked = 0
        let first = try await watch.check(account, at: start) { _ in asked += 1; return [self.alert("old", -30)] }
        XCTAssertNil(first, "Nothing is new the first time")
        XCTAssertEqual(asked, 0, "The first check only marks where watching starts")

        var since: Date?
        let later = try await watch.check(account, at: start.addingTimeInterval(300)) { from in
            since = from
            return [self.alert("b", 4), self.alert("a", 2), self.alert("old", -30)]
        }
        XCTAssertEqual(since, start)
        XCTAssertEqual(later?.count, 2, "Only what came after watching started")
        XCTAssertEqual(later?.since, alert("a", 2).time)
        XCTAssertEqual(later?.until, alert("b", 4).time)
        XCTAssertEqual(later?.capped, false)
    }

    func testAlertsAlreadySeenAreNotNewAgainButOnesListedLateAre() async throws {
        var watch = AlertWatch()
        _ = try await watch.check(account, at: start) { _ in [] }
        _ = try await watch.check(account, at: start.addingTimeInterval(1_800)) { _ in [self.alert("a", 10), self.alert("b", 25)] }

        // Services list some alerts after their time, so each check looks back an hour from the newest one seen.
        var since: Date?
        let next = try await watch.check(account, at: start.addingTimeInterval(2_100)) { from in
            since = from
            return [self.alert("b", 25), self.alert("late", 20), self.alert("a", 10)]
        }
        XCTAssertEqual(since, start, "An hour back from the newest seen, but never before watching started")
        XCTAssertEqual(next?.count, 1)
        XCTAssertEqual(next?.since, alert("late", 20).time)

        let quiet = try await watch.check(account, at: start.addingTimeInterval(2_400)) { _ in [self.alert("b", 25), self.alert("late", 20)] }
        XCTAssertNil(quiet)

        _ = try await watch.check(account, at: start.addingTimeInterval(9_000)) { _ in [self.alert("c", 140)] }
        let much = try await watch.check(account, at: start.addingTimeInterval(9_300)) { from in
            since = from
            return []
        }
        XCTAssertNil(much)
        XCTAssertEqual(since, alert("c", 80).time)
    }

    func testABurstAtTheLimitIsSaidToBeMore() async throws {
        var watch = AlertWatch()
        _ = try await watch.check(account, at: start) { _ in [] }
        let burst = try await watch.check(account, at: start.addingTimeInterval(300)) { _ in
            (0..<ServiceAlert.most).map { self.alert("a\($0)", 1) }
        }
        XCTAssertEqual(burst?.capped, true)
    }

    func testAnAccountNoLongerWatchedStartsAfreshWhenWatchedAgain() async throws {
        var watch = AlertWatch()
        _ = try await watch.check(account, at: start) { _ in [] }
        watch.keep(only: [])
        let again = try await watch.check(account, at: start.addingTimeInterval(600)) { _ in [self.alert("a", 5)] }
        XCTAssertNil(again, "Watched again, it starts from then")
    }

    func testWhatWasSeenIsKeptAcrossLaunches() async throws {
        var watch = AlertWatch()
        _ = try await watch.check(account, at: start) { _ in [] }
        _ = try await watch.check(account, at: start.addingTimeInterval(300)) { _ in [self.alert("a", 2)] }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try watch.save(to: file)
        var loaded = AlertWatch.load(from: file)
        XCTAssertEqual(loaded, watch)
        let next = try await loaded.check(account, at: start.addingTimeInterval(600)) { _ in [self.alert("a", 2)] }
        XCTAssertNil(next)
        XCTAssertEqual(AlertWatch.load(from: file.appendingPathExtension("missing")), AlertWatch())
    }

    func testTheNoteSaysOnlyWhereToLookNotWhatWasFound() {
        let news = AlertWatch.News(count: 3, capped: false, since: Date(timeIntervalSince1970: 1_800_000_000.4),
                                   until: Date(timeIntervalSince1970: 1_800_000_240.2))
        XCTAssertEqual(AlertWatch.note(news, account: #"Defender — "Kestrel" & co"#, skill: "mcp-defender", tool: "alerts"),
                       #"<pion-alerts account="Defender — &quot;Kestrel&quot; &amp; co" skill=".agents/skills/mcp-defender/SKILL.md" tool="alerts" new="3" since="2027-01-15T08:00:00Z" until="2027-01-15T08:04:01Z" />"#)
        let more = AlertWatch.News(count: ServiceAlert.most, capped: true, since: Date(timeIntervalSince1970: 1_800_000_000),
                                   until: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(AlertWatch.note(more, account: "Wiz", skill: "mcp-wiz", tool: "issues").contains(#"new="\#(ServiceAlert.most)+""#))
    }
}
