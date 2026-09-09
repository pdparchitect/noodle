import Foundation
import Security

/// Keep the vendor requirement enforced while preserving the reason a check failed.
enum HarnessSignatureVerification {
    static func verify(_ url: URL, requirement rule: String, signatureName: String) throws {
        var code: SecStaticCode?
        let loadStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard loadStatus == errSecSuccess, let code else {
            throw failure(signatureName, stage: "loading the executable", status: loadStatus)
        }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(rule as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw failure(signatureName, stage: "preparing the signature requirement", status: requirementStatus)
        }

        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else {
            throw failure(signatureName, stage: "checking the signature", status: status)
        }
    }

    static func failure(_ signatureName: String, stage: String, status: OSStatus) -> HarnessSetupError {
        let code = status == errSecSuccess ? errSecInternalComponent : status
        let detail = SecCopyErrorMessageString(code, nil).map { $0 as String } ?? "Unknown macOS security error"
        return HarnessSetupError("\(signatureName) could not be verified. macOS error \(code) while \(stage): \(detail)")
    }
}
