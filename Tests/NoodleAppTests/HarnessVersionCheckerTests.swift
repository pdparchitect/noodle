import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class HarnessVersionCheckerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let installation = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
    private let release = Data(#"{"tag_name":"rust-v3.0.0"}"#.utf8)

    func testFreshCacheReusesLatestVersionButStillInspectsInstalledBinary() async throws {
        var inspected = 0, fetched = 0
        let checker = HarnessVersionChecker(inspect: { _ in inspected += 1; return .init(installedVersion: "2.0.0") },
            fetch: { _ in fetched += 1; return self.release }, now: { self.now })
        let previous = HarnessVersionReport(installedVersion: "1.0.0", latestVersion: "2.5.0", latestCheckedAt: now.addingTimeInterval(-60))
        let report = try await checker.check(installation, previous: previous, forceLatest: false)
        XCTAssertEqual(report.installedVersion, "2.0.0"); XCTAssertEqual(report.latestVersion, "2.5.0")
        XCTAssertEqual(inspected, 1); XCTAssertEqual(fetched, 0)
    }

    func testForcedExpiredAndFutureDatedCachesFetchProviderRelease() async throws {
        for (age, forced) in [(60.0, true), (6 * 3600.0, false), (-60.0, false)] {
            var fetched: [URL] = []
            let checker = HarnessVersionChecker(inspect: { _ in .init(installedVersion: "2.0.0") },
                fetch: { fetched.append($0); return self.release }, now: { self.now })
            let previous = HarnessVersionReport(latestVersion: "2.5.0", latestCheckedAt: now.addingTimeInterval(-age))
            let report = try await checker.check(installation, previous: previous, forceLatest: forced)
            XCTAssertEqual(report.latestVersion, "3.0.0"); XCTAssertEqual(report.latestCheckedAt, now)
            XCTAssertEqual(fetched, [HarnessVersionPolicy.latestURL(for: installation)!])
        }
    }

    func testUnavailableOrInvalidReleasePreservesLastKnownVersionAndTimestamp() async throws {
        for fails in [false, true] {
            let checker = HarnessVersionChecker(inspect: { _ in .init(installedVersion: "2.0.0", compatibilityIssue: "Missing protocol") },
                fetch: { _ in if fails { throw HarnessSetupError("Offline") }; return Data("invalid response".utf8) }, now: { self.now })
            let previous = HarnessVersionReport(latestVersion: "2.5.0", latestCheckedAt: now.addingTimeInterval(-30_000))
            let report = try await checker.check(installation, previous: previous, forceLatest: false)
            XCTAssertEqual(report.latestVersion, previous.latestVersion); XCTAssertEqual(report.latestCheckedAt, previous.latestCheckedAt)
            XCTAssertEqual(report.compatibilityIssue, "Missing protocol"); XCTAssertNotNil(report.checkError)
        }
    }

    func testBundledHarnessesDoNotFetchStandaloneReleaseMetadata() async throws {
        let checker = HarnessVersionChecker(inspect: { _ in .init(installedVersion: "2.0.0") },
            fetch: { _ in XCTFail("Bundled executable fetched standalone release"); return self.release })
        for installation in [HarnessInstallation(provider: .codex, executablePath: "/Applications/Codex.app/Contents/Resources/codex"),
                             HarnessInstallation(provider: .apple, executablePath: "/fixtures/AppleAgent")] {
            let report = try await checker.check(installation, previous: .init(latestVersion: "8.0.0", latestCheckedAt: now), forceLatest: true)
            XCTAssertEqual(report.installedVersion, "2.0.0"); XCTAssertNil(report.latestVersion); XCTAssertNil(report.latestCheckedAt)
        }
    }

    func testCancelledReleaseFetchDoesNotReturnLateSuccess() async throws {
        let gate = RoutingGate<Data>()
        let checker = HarnessVersionChecker(inspect: { _ in .init(installedVersion: "2.0.0") }, fetch: { _ in try await gate.value() })
        let task = Task { try await checker.check(installation, previous: nil, forceLatest: true) }
        await fulfillment(of: [gate.entered], timeout: 2)
        task.cancel(); gate.resolve(.success(release))
        do { _ = try await task.value; XCTFail("Cancelled check returned a release") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
