import XCTest
@testable import ComputerBridge

final class BuildIdentityTests: XCTestCase {
    func testDocumentRegistrationsAndExtensionIdentitiesStayInTheirChannel() {
        XCTAssertEqual(ComputerBuildIdentity.development.fileExtension, "noodlecomputer-dev")
        XCTAssertEqual(ComputerBuildIdentity.development.storageName, "Noodle Computer Local")
        for build in ComputerBuildIdentity.allCases {
            XCTAssertEqual(ComputerBuildIdentity.identify(build.providerID + ".preview"), build)
            XCTAssertEqual(ComputerBuildIdentity.identify(build.providerID + ".thumbnail"), build)
            for other in ComputerBuildIdentity.allCases where other != build {
                XCTAssertNotEqual(build.fileExtension, other.fileExtension)
                XCTAssertNotEqual(build.contentType, other.contentType)
            }
        }
    }
    func testEachNoodleFindsOnlyItsMatchingProvider() {
        let release = ComputerBuildIdentity.identify("com.pdparchitect.noodle")
        let local = ComputerBuildIdentity.identify("com.pdparchitect.noodle.local")
        XCTAssertEqual(release?.providerID, "com.pdparchitect.noodle.computer")
        XCTAssertEqual(local?.providerID, "com.pdparchitect.noodle.computer.local")
        XCTAssertEqual(local?.appName, "Noodle Computer Dev")
        for build in ComputerBuildIdentity.allCases {
            XCTAssertEqual(ComputerBuildIdentity.identify(build.providerID), build)
            for other in ComputerBuildIdentity.allCases where other != build {
                XCTAssertNotEqual(build.providerID, other.providerID)
                XCTAssertNotEqual(build.groupSuffix, other.groupSuffix)
                XCTAssertTrue(Set(build.clientIDs).isDisjoint(with: other.clientIDs))
            }
        }
        XCTAssertNil(ComputerBuildIdentity.identify("com.pdparchitect.noodle.computer.local.other"))
        XCTAssertNil(ComputerBuildIdentity.identify(nil))
    }

    func testMispackagedLocalAppCannotUseProductionSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "com.pdparchitect.noodle.local", "CFBundlePackageType": "APPL",
                    "NoodleSigningTeam": "ABCDEFGHIJ", "NoodleComputerGroup": "ABCDEFGHIJ.com.pdparchitect.noodle.computers"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertThrowsError(try ComputerConnection.socketURL(bundle: bundle)) {
            XCTAssertTrue($0.localizedDescription.contains("does not match"))
        }
    }
}
