import Foundation

extension HarnessDistribution {
    /// As https://x.ai/cli/install.sh reads it: a plain version pointer and one
    /// executable. xAI publishes no checksum, so the signature check in the Agent
    /// Host is the only verification.
    static let grokBuild: HarnessDistribution = {
        let platform = "macos-aarch64"
        return HarnessDistribution(
            provider: .grokBuild, executablePath: "grok", isArchive: false,
            latest: URL(string: "https://x.ai/cli/stable")!, hosts: ["x.ai"],
            version: { HarnessVersionPolicy.latestVersion(provider: .grokBuild, data: $0) },
            addresses: { ("https://x.ai/cli/grok-\($0)-\(platform)", nil) },
            expectation: { _, _ in nil },
            verify: { _, executable in try GrokExecutableTrust.verifySignature(executable) })
    }()
}
