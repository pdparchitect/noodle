import AppletBridge
import AppletCore
import XCTest

final class BuildIdentityTests: XCTestCase {
    func testOldDevelopmentDocumentsAndLinksRemainDevOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["noodlet.json": Data(#"{"title":"Fixture","runtime":"html","entry":"index.html"}"#.utf8), "index.html": Data("fixture".utf8)]
        let current = root.appendingPathComponent("Example.noodlet-dev")
        _ = try NoodletPackage.install(files, to: current, build: .development)
        let legacy = root.appendingPathComponent("Example.noodlet-local")
        try FileManager.default.moveItem(at: current, to: legacy)
        XCTAssertEqual(try NoodletPackage(url: legacy, build: .development).files(), files)
        XCTAssertThrowsError(try NoodletPackage(url: legacy, build: .production))
        XCTAssertThrowsError(try NoodletPackage.install(files, to: legacy, build: .development))
        let id = UUID(), oldLink = URL(string: "noodlet-local://" + UUID().uuidString)!
        XCTAssertEqual(NoodletLink.canonical(oldLink)?.scheme, "noodlet-dev")
        XCTAssertEqual(try NoodletLink.requireID(in: oldLink, build: .development), NoodletLink.id(in: oldLink))
        XCTAssertThrowsError(try NoodletLink.requireID(in: oldLink, build: .production))
        XCTAssertEqual(NoodletLink.url(for: id, build: .development).scheme, "noodlet-dev")
        XCTAssertNil(NoodletLink.canonical(URL(string: oldLink.absoluteString + "?x=1")!))
    }
    func testNamespacesAndPeerAllowListsAreDisjoint() throws {
        let prod = AppletBuildIdentity.production, local = AppletBuildIdentity.development
        for build in AppletBuildIdentity.allCases {
            for id in [build.providerID, build.noodleID, build.cliID, build.previewID] {
                XCTAssertEqual(AppletBuildIdentity.identify(id), build)
            }
            try build.validateGroup("TEAM123456." + build.groupSuffix, team: "TEAM123456")
            XCTAssertThrowsError(try build.validateGroup("TEAM123456." + (build == prod ? local : prod).groupSuffix, team: "TEAM123456"))
        }
        XCTAssertTrue(Set(prod.clientIDs).isDisjoint(with: local.clientIDs))
        XCTAssertNotEqual(prod.groupSuffix, local.groupSuffix)
        XCTAssertNotEqual(prod.contentType, local.contentType)
        XCTAssertNil(AppletBuildIdentity.identify(local.providerID + ".unknown"))
    }
    func testLinksPreserveTheirEnvironmentAndRejectCrossEnvironmentOpens() throws {
        let id = UUID()
        for build in AppletBuildIdentity.allCases {
            let url = NoodletLink.url(for: id, build: build)
            XCTAssertEqual(url.scheme, build.urlScheme)
            XCTAssertEqual(NoodletLink.canonical(url), url)
            XCTAssertEqual(NoodletLink.id(in: url), id)
            XCTAssertEqual(try NoodletLink.requireID(in: url, build: build), id)
            XCTAssertThrowsError(try NoodletLink.requireID(in: url, build: build == .production ? .development : .production)) {
                XCTAssertEqual(($0 as? AppletError)?.code, "environment-mismatch")
            }
            for suffix in ["/", "?environment=production", "#fragment", ":80"] {
                XCTAssertNil(NoodletLink.canonical(URL(string: url.absoluteString + suffix)!))
            }
        }
    }
    func testDiscoveryNeverFallsBackToTheOtherEnvironment() {
        let local = URL(fileURLWithPath: "/build/Noodle Applet Dev.app")
        let prod = URL(fileURLWithPath: "/Applications/Noodle Applet.app")
        let identify: (URL) -> String? = { $0 == local ? AppletBuildIdentity.development.providerID : $0 == prod ? AppletBuildIdentity.production.providerID : nil }
        XCTAssertEqual(AppletApplication.select(running: [prod, local], sibling: local, registered: prod, build: .development, identify: identify), local)
        XCTAssertNil(AppletApplication.select(running: [prod], sibling: nil, registered: prod, build: .development, identify: identify))
        XCTAssertEqual(AppletApplication.select(running: [local, prod], sibling: local, registered: prod, build: .production, identify: identify), prod)
        XCTAssertNil(AppletApplication.select(running: [local], sibling: local, registered: local, build: .production, identify: identify))
    }
    func testConversionCopiesAndDoesNotOverwriteEitherDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["noodlet.json": Data(#"{"title":"Fixture","runtime":"html","entry":"index.html"}"#.utf8), "index.html": Data("original".utf8)]
        let source = try NoodletPackage.install(files, to: root.appendingPathComponent("Original.noodlet"), build: .production)
        let destination = root.appendingPathComponent("Copy.noodlet-dev")
        XCTAssertThrowsError(try NoodletPackage(url: source.url, build: .development))
        XCTAssertThrowsError(try NoodletPackage.install(files, to: source.url, build: .development))
        let copy = try NoodletPackage.convert(from: source.url, to: destination)
        XCTAssertEqual(try copy.files(), files)
        XCTAssertEqual(try source.files(), files)
        XCTAssertThrowsError(try NoodletPackage(url: copy.url, build: .production))
        try Data("edited copy".utf8).write(to: destination.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try NoodletPackage.convert(from: source.url, to: destination))
        XCTAssertEqual(try source.files()["index.html"], files["index.html"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("index.html")), Data("edited copy".utf8))
        XCTAssertThrowsError(try NoodletPackage.convert(from: source.url, to: source.url))
    }
    func testUpdateCheckURLStaysInItsBuildChannelAndIsNotANoodletLink() {
        for build in AppletBuildIdentity.allCases {
            let url = AppletLaunch.updateCheckURL(for: build)
            XCTAssertEqual(url.absoluteString, build.urlScheme + "://updates/check")
            XCTAssertNil(NoodletLink.id(in: url))
        }
    }
}
