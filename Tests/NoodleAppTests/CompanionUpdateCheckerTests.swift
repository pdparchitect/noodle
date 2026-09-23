import Foundation
import XCTest
@testable import Noodle
@testable import NoodleRuntimeSettings

@MainActor final class CompanionUpdateCheckerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let feed = "https://example.com/appcast.xml"
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("companion-updates-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installation(version: String = "1.0.0", feed: String? = nil, updatesEnabled: Bool = true,
                              acceptsUpdateCheck: Bool = true) throws -> CompanionAppInstallation {
        let app = root.appendingPathComponent("\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleVersion": version,
                                   "NoodleUpdatesEnabled": updatesEnabled]
        info["SUFeedURL"] = feed ?? self.feed
        if acceptsUpdateCheck { info["NoodleAcceptsUpdateCheck"] = true }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(CompanionAppInstallation(applicationURL: app))
    }

    private func appcast(_ items: String...) -> Data {
        Data("""
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
        \(items.joined(separator: "\n"))
        </channel></rss><!-- sparkle-signatures: edSignature: AAAA -->
        """.utf8)
    }

    private func item(_ version: String, display: String? = nil, extra: String = "") -> String {
        "<item><title>\(version)</title><sparkle:version>\(version)</sparkle:version>"
            + "<sparkle:shortVersionString>\(display ?? version)</sparkle:shortVersionString>\(extra)</item>"
    }

    func testInstallationReadsUpdateMetadataFromBundle() throws {
        let installed = try installation(version: "1.2.3")
        XCTAssertEqual(installed.buildVersion, "1.2.3")
        XCTAssertEqual(installed.feedURL, URL(string: feed))
        XCTAssertTrue(installed.updatesEnabled)
    }

    func testUpdateCheckIsRequestedOnlyFromABehindCompanionThatAcceptsIt() throws {
        let release = CompanionRelease(version: "2.0.0", displayVersion: "2.0.0")
        for app in CompanionApp.allCases {
            let url = try XCTUnwrap(app.updateCheckURL(for: try installation(), update: release), app.name)
            XCTAssertEqual(url.host, "updates", app.name)
            XCTAssertEqual(url.path, "/check", app.name)
            XCTAssertNil(app.updateCheckURL(for: try installation(), update: nil), app.name)
            // A companion from before the request would report an invalid link.
            XCTAssertNil(app.updateCheckURL(for: try installation(acceptsUpdateCheck: false), update: release), app.name)
            XCTAssertNil(app.updateCheckURL(for: nil, update: release), app.name)
        }
    }

    func testEveryCompanionDeclaresThatItAcceptsAnUpdateCheckAndOwnsAURLScheme() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for companion in ["Browser", "Computer", "Applet"] {
            let data = try Data(contentsOf: repository.appendingPathComponent("\(companion)/Support/Info.plist"))
            let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(info["NoodleAcceptsUpdateCheck"] as? Bool, true, companion)
            let types = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]], companion)
            XCTAssertFalse((types.first?["CFBundleURLSchemes"] as? [String] ?? []).isEmpty, companion)
        }
    }

    func testNewerFeedReleaseIsReportedAndCurrentOrOlderIsNot() async throws {
        let data = appcast(item("1.9.0"), item("1.10.0", display: "1.10"))
        let checker = CompanionUpdateChecker(fetch: { _ in data }, now: { self.now })
        let behind = await checker.availableUpdate(for: try installation(version: "1.9.0"), force: false)
        XCTAssertEqual(behind, CompanionRelease(version: "1.10.0", displayVersion: "1.10"))
        let current = await checker.availableUpdate(for: try installation(version: "1.10.0"), force: false)
        XCTAssertNil(current)
        let ahead = await checker.availableUpdate(for: try installation(version: "2.0.0"), force: false)
        XCTAssertNil(ahead)
    }

    func testDisabledUpdatesAndInsecureFeedsAreNeverFetched() async throws {
        let checker = CompanionUpdateChecker(fetch: { _ in XCTFail("Fetched a feed that must be skipped"); return Data() })
        let disabled = await checker.availableUpdate(for: try installation(updatesEnabled: false), force: true)
        XCTAssertNil(disabled)
        let insecure = await checker.availableUpdate(for: try installation(feed: "http://example.com/appcast.xml"), force: true)
        XCTAssertNil(insecure)
    }

    func testFreshResultIsReusedUntilForcedOrExpired() async throws {
        var fetched = 0, clock = now
        let data = appcast(item("2.0.0"))
        let checker = CompanionUpdateChecker(fetch: { _ in fetched += 1; return data }, now: { clock })
        let installed = try installation()
        _ = await checker.availableUpdate(for: installed, force: false)
        _ = await checker.availableUpdate(for: installed, force: false)
        XCTAssertEqual(fetched, 1)
        _ = await checker.availableUpdate(for: installed, force: true)
        XCTAssertEqual(fetched, 2)
        clock = now.addingTimeInterval(6 * 60 * 60)
        _ = await checker.availableUpdate(for: installed, force: false)
        XCTAssertEqual(fetched, 3)
    }

    func testUnreachableFeedKeepsLastKnownReleaseAndInstallingItClearsTheNotice() async throws {
        var offline = false
        let data = appcast(item("2.0.0"))
        let checker = CompanionUpdateChecker(fetch: { _ in if offline { throw URLError(.notConnectedToInternet) }; return data },
                                             now: { self.now })
        _ = await checker.availableUpdate(for: try installation(), force: false)
        offline = true
        let stillBehind = await checker.availableUpdate(for: try installation(), force: true)
        XCTAssertEqual(stillBehind?.version, "2.0.0")
        let updated = await checker.availableUpdate(for: try installation(version: "2.0.0"), force: false)
        XCTAssertNil(updated)
    }

    func testRefreshPublishesOnlyCompanionsThatAreBehindAndClearsThemOnceUpdated() async throws {
        let data = appcast(item("2.0.0"))
        let checker = CompanionUpdateChecker(fetch: { _ in data }, now: { self.now })
        await checker.refresh([.browser: try installation(), .applet: try installation(version: "2.0.0"),
                               .computer: try installation(updatesEnabled: false)]).value
        XCTAssertEqual(checker.updates, [.browser: CompanionRelease(version: "2.0.0", displayVersion: "2.0.0")])
        await checker.refresh([.browser: try installation(version: "2.0.0")]).value
        XCTAssertTrue(checker.updates.isEmpty)
    }

    func testAppcastSkipsReleasesThisMacCannotRunAndOtherChannels() {
        let data = appcast(
            item("1.5.0"),
            item("2.0.0", extra: "<sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>"),
            item("3.0.0", extra: "<sparkle:channel>beta</sparkle:channel>"),
            item("1.6.0", extra: "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>"))
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        XCTAssertEqual(CompanionAppcast.latestRelease(in: data, systemVersion: system, isAppleSilicon: true)?.version, "1.6.0")
        XCTAssertEqual(CompanionAppcast.latestRelease(in: data, systemVersion: system, isAppleSilicon: false)?.version, "1.5.0")
        let newer = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(CompanionAppcast.latestRelease(in: data, systemVersion: newer, isAppleSilicon: true)?.version, "2.0.0")
    }

    func testAppcastReadsVersionFromEnclosureAndRejectsMalformedFeeds() {
        let enclosure = appcast(#"<item><enclosure url="https://example.com/a.zip" sparkle:version="4" sparkle:shortVersionString="1.4"/></item>"#)
        XCTAssertEqual(CompanionAppcast.latestRelease(in: enclosure), CompanionRelease(version: "4", displayVersion: "1.4"))
        XCTAssertNil(CompanionAppcast.latestRelease(in: Data("not a feed".utf8)))
        XCTAssertNil(CompanionAppcast.latestRelease(in: appcast()))
    }
}
