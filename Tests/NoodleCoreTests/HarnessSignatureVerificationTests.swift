import Security
import XCTest
@testable import NoodleCore

final class HarnessSignatureVerificationTests: XCTestCase {
    func testFailureIncludesProviderStageAndMacOSError() {
        let error = HarnessSignatureVerification.failure("FX’s Vercel signature",
            stage: "checking the signature", status: errSecCSReqFailed)
        XCTAssertTrue(error.localizedDescription.contains("FX’s Vercel signature could not be verified."))
        XCTAssertTrue(error.localizedDescription.contains("macOS error \(errSecCSReqFailed)"))
        XCTAssertTrue(error.localizedDescription.contains("checking the signature"))
        let detail = SecCopyErrorMessageString(errSecCSReqFailed, nil)! as String
        XCTAssertTrue(error.localizedDescription.contains(detail))
    }

    func testMissingFxExecutableReportsLoadingFailure() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fx-missing-\(UUID())")
            .resolvingSymlinksInPath()
        XCTAssertThrowsError(try FxExecutableTrust.executable(at: root.appendingPathComponent(".local/bin/fx").path, home: root)) {
            XCTAssertTrue($0.localizedDescription.contains("FX’s Vercel signature could not be verified. macOS error "))
            XCTAssertTrue($0.localizedDescription.contains("loading the executable"))
        }
    }

    func testWrongVendorRequirementIsStillRejected() {
        XCTAssertThrowsError(try HarnessSignatureVerification.verify(URL(fileURLWithPath: "/usr/bin/true"),
            requirement: "anchor apple generic and identifier \"com.vercel.fx\" and certificate leaf[subject.OU] = \"JW6Y669B67\"",
            signatureName: "FX’s Vercel signature")) {
            XCTAssertTrue($0.localizedDescription.contains("checking the signature"))
            XCTAssertTrue($0.localizedDescription.contains("macOS error "))
        }
    }
}
