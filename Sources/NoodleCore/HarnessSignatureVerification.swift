import Foundation
#if canImport(Security)
import Security
#endif

/// Keep the vendor requirement enforced while preserving the reason a check failed.
enum HarnessSignatureVerification {
    static func verify(_ url: URL, requirement rule: String, signatureName: String) throws {
        try VerifiedExecutables.verify(url, requirement: rule) {
            if let unmet = unmet(url, requirement: rule) { throw failure(signatureName, stage: unmet.stage, status: unmet.status) }
        }
    }

    /// Where checking `url` against the code-signing `rule` stopped, with the system's status, or
    /// nil when it meets it. `strict` is the check for code shipped inside the app. Only macOS
    /// signs code this way, so elsewhere nothing meets a rule.
    static func unmet(_ url: URL, requirement rule: String, strict: Bool = false) -> (stage: String, status: Int32)? {
        #if canImport(Security)
        var code: SecStaticCode?
        let loadStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard loadStatus == errSecSuccess, let code else { return ("loading the executable", loadStatus) }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(rule as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else { return ("preparing the signature requirement", requirementStatus) }

        let flags = SecCSFlags(rawValue: strict ? kSecCSStrictValidate : kSecCSCheckAllArchitectures)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        return status == errSecSuccess ? nil : ("checking the signature", status)
        #else
        return ("checking the signature", -1)
        #endif
    }

    static func failure(_ signatureName: String, stage: String, status: Int32) -> HarnessSetupError {
        #if canImport(Security)
        let code = status == errSecSuccess ? errSecInternalComponent : status
        let detail = SecCopyErrorMessageString(code, nil).map { $0 as String } ?? "Unknown macOS security error"
        return HarnessSetupError("\(signatureName) could not be verified. macOS error \(code) while \(stage): \(detail)")
        #else
        return HarnessSetupError("\(signatureName) could not be verified: only macOS checks code signatures.")
        #endif
    }
}
