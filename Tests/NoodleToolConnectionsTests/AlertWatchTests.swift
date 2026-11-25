import Foundation
import XCTest
@testable import NoodleToolConnections

/// What the watcher every app runs keeps of each watched account, and the note that wakes its agents.
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

    /// A service that lists some alerts hours late says how far back to read: an alert listed late within that is found
    /// once, and remembered so it is not new again.
    func testALongerLookBackFindsAnAlertListedHoursLateOnce() async throws {
        var watch = AlertWatch()
        let lookBack: TimeInterval = 6 * 3_600
        _ = try await watch.check(account, at: start, lookBack: lookBack) { _ in [] }
        _ = try await watch.check(account, at: start.addingTimeInterval(9_000), lookBack: lookBack) { _ in [self.alert("recent", 120)] }
        var since: Date?
        let late = try await watch.check(account, at: start.addingTimeInterval(9_300), lookBack: lookBack) { from in
            since = from
            return [self.alert("recent", 120), self.alert("late", 10)]
        }
        XCTAssertEqual(since, start, "six hours back from the newest seen, but never before watching started")
        XCTAssertEqual(late?.count, 1)
        let again = try await watch.check(account, at: start.addingTimeInterval(9_600), lookBack: lookBack) { _ in
            [self.alert("recent", 120), self.alert("late", 10)]
        }
        XCTAssertNil(again, "an alert listed late is news once")
    }

    /// An account with nothing new for days reads back only from its last quiet check, not from when watching started,
    /// even when all it ever found was a notice dated at the start of the window read; the notice itself moves nothing.
    func testAQuietAccountReadsBackFromItsLastQuietCheckNotFromWhenWatchingStarted() async throws {
        var watch = AlertWatch()
        let lookBack: TimeInterval = 6 * 3_600
        _ = try await watch.check(account, at: start, lookBack: lookBack) { _ in [] }
        let day = start.addingTimeInterval(86_400)
        let notice = try await watch.check(account, at: day, lookBack: lookBack) { from in [ServiceAlert(id: "unchecked/1", time: from)] }
        XCTAssertNotNil(notice)
        var since: Date?
        _ = try await watch.check(account, at: day.addingTimeInterval(300), lookBack: lookBack) { from in since = from; return [] }
        XCTAssertEqual(since, start, "the check that told the notice moved nothing")
        _ = try await watch.check(account, at: day.addingTimeInterval(600), lookBack: lookBack) { from in since = from; return [] }
        XCTAssertEqual(since, day.addingTimeInterval(300 - lookBack), "six hours back from the last quiet check")
    }

    /// A check that fails moves nothing on, so the next reads the same window again.
    func testAFailedCheckDoesNotMoveTheWindow() async throws {
        var watch = AlertWatch()
        _ = try await watch.check(account, at: start) { _ in [] }
        _ = try? await watch.check(account, at: start.addingTimeInterval(7_200)) { _ in throw CancellationError() }
        var since: Date?
        _ = try await watch.check(account, at: start.addingTimeInterval(7_500)) { from in since = from; return [] }
        XCTAssertEqual(since, start)
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
                       #"<tool-alerts account="Defender — &quot;Kestrel&quot; &amp; co" skill=".agents/skills/mcp-defender/SKILL.md" tool="alerts" new="3" since="2027-01-15T08:00:00Z" until="2027-01-15T08:04:01Z" />"#)
        let more = AlertWatch.News(count: ServiceAlert.most, capped: true, since: Date(timeIntervalSince1970: 1_800_000_000),
                                   until: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(AlertWatch.note(more, account: "Wiz", skill: "mcp-wiz", tool: "issues").contains(#"new="\#(ServiceAlert.most)+""#))
    }

    /// A board, such as a ranking, wakes only for what is newly on it: the first check notes what is there, and what
    /// leaves and comes back within a week is not new again.
    func testABoardWakesOnlyForWhatIsNewlyOnIt() async throws {
        var watch = AlertWatch()
        let first = watch.board(account, at: start, found: ["a", "b"])
        XCTAssertNil(first, "What is on it when first watched is not new")
        let next = watch.board(account, at: start.addingTimeInterval(3_600), found: ["c", "a", "b"])
        XCTAssertEqual(next, ["c"])
        let same = watch.board(account, at: start.addingTimeInterval(7_200), found: ["c", "a"])
        XCTAssertNil(same)
        let back = watch.board(account, at: start.addingTimeInterval(86_400), found: ["b", "c", "a"])
        XCTAssertNil(back, "Back within the week")
        let later = watch.board(account, at: start.addingTimeInterval(9 * 86_400), found: ["c", "b"])
        XCTAssertEqual(later, ["c", "b"], "Gone for over a week, so new again")
    }

    func testABoardsNoteNamesWhatIsNewOnIt() {
        XCTAssertEqual(AlertWatch.note(["CVE-2026-1", "CVE-2026-2"], account: "cve.now", skill: "mcp-cve-now", tool: "execute"),
                       #"<tool-alerts account="cve.now" skill=".agents/skills/mcp-cve-now/SKILL.md" tool="execute" new="2" entries="CVE-2026-1,CVE-2026-2" />"#)
    }
}
