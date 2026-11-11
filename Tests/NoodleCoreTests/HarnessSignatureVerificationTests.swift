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

    /// Each harness names its own vendor when a signature does not hold.
    func testEachTrustRejectsAnotherVendorsSignatureInItsOwnWords() throws {
        let other = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertThrowsError(try ClaudeExecutableTrust.verifySignature(other)) {
            XCTAssertEqual($0.localizedDescription, "Claude Code’s Anthropic signature could not be verified.")
        }
        XCTAssertThrowsError(try CodexExecutableTrust.verifySignature(other, identifier: "codex")) {
            XCTAssertEqual($0.localizedDescription, "Codex’s OpenAI signature could not be verified.")
        }
    }

    /// The bundled Apple harness passes a strict check of the requirement it is given, and nothing else does.
    func testTheAppleHarnessMustMeetItsRequirement() throws {
        let application = FileManager.default.temporaryDirectory.appendingPathComponent("apple-harness-\(UUID()).app")
            .resolvingSymlinksInPath()
        let helpers = application.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: application) }
        let agent = helpers.appendingPathComponent("NoodleAppleAgent")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: agent)
        XCTAssertEqual(try AppleExecutableTrust.executable(at: agent.path, application: application,
                                                           requirement: "anchor apple and identifier \"com.apple.true\""), agent)
        XCTAssertThrowsError(try AppleExecutableTrust.executable(at: agent.path, application: application,
                                                                 requirement: "anchor apple and identifier \"com.pdparchitect.noodle\"")) {
            XCTAssertEqual($0.localizedDescription, "The bundled Apple harness signature is invalid. Reinstall Noodle.")
        }
    }

    func testAnAppleSignedExecutableMeetsAnAppleRequirement() throws {
        XCTAssertNoThrow(try HarnessSignatureVerification.verify(URL(fileURLWithPath: "/usr/bin/true"),
            requirement: "anchor apple and identifier \"com.apple.true\"", signatureName: "Apple’s signature"))
    }
}
