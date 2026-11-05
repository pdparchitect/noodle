import ComputerBridge
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

final class ComputerIdleWatchTests: XCTestCase {
    private let computer = UUID(), agent = UUID(), start = Date(timeIntervalSince1970: 1_000_000)
    private func minutes(_ value: Double) -> Date { start.addingTimeInterval(value * 60) }

    func testAComputerAnAgentLeftRunningUnusedIsReportedOncePerIdleStretch() {
        var watch = ComputerIdleWatch()
        watch.started(computer, caller: "noodle", agentID: agent, at: start)
        watch.used(computer, at: minutes(10))
        let running: (UUID) -> ComputerIdleWatch.Running? = { _ in .init(name: "Build box", watched: false) }
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(29), running: running), [], "Not running long enough")
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(24.5), running: running), [], "Used too recently")
        let due = watch.due(for: "noodle", at: minutes(31), running: running)
        XCTAssertEqual(due.map(\.computerID), [computer])
        XCTAssertEqual(due.first?.agentID, agent)
        XCTAssertEqual(due.first?.note, "Build box has been running for 31 minutes and nothing has used it for 21. If you no longer need it, stop it; its files stay.")
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(45), running: running), [], "Reported once")
        watch.used(computer, at: minutes(46))
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(60), running: running), [])
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(61), running: running).map(\.computerID), [computer], "Used again, then left again")
    }

    func testOnlyTheAppWhoseAgentStartedItIsTold() {
        var watch = ComputerIdleWatch()
        watch.started(computer, caller: "noodle", agentID: agent, at: start)
        let running: (UUID) -> ComputerIdleWatch.Running? = { _ in .init(name: "Build box", watched: false) }
        XCTAssertEqual(watch.due(for: "hub", at: minutes(60), running: running), [])
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(60), running: running).count, 1)
    }

    func testAStoppedComputerIsForgottenEvenIfSomeoneStartsItAgain() {
        var watch = ComputerIdleWatch()
        watch.started(computer, caller: "noodle", agentID: agent, at: start)
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(5), running: { _ in nil }), [])
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(60), running: { _ in .init(name: "Build box", watched: false) }), [])
        watch.started(computer, caller: "noodle", agentID: agent, at: start)
        watch.stopped(computer)
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(60), running: { _ in .init(name: "Build box", watched: false) }), [])
    }

    func testAComputerSomeoneIsWatchingIsInUse() {
        var watch = ComputerIdleWatch()
        watch.started(computer, caller: "noodle", agentID: agent, at: start)
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(40), running: { _ in .init(name: "Build box", watched: true) }), [])
        let running: (UUID) -> ComputerIdleWatch.Running? = { _ in .init(name: "Build box", watched: false) }
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(50), running: running), [], "Watching counted as use")
        XCTAssertEqual(watch.due(for: "noodle", at: minutes(55), running: running).count, 1)
    }
}
