import Foundation

extension HarnessDistribution {
    /// As https://gh.io/copilot-install reads it: the GitHub release names the
    /// version, and its assets carry the package and a SHA-256 listing.
    static let copilot: HarnessDistribution = {
        let platform = "darwin-arm64"
        return HarnessDistribution(
            provider: .copilot, executablePath: "copilot", isArchive: true,
            latest: URL(string: "https://api.github.com/repos/github/copilot-cli/releases/latest")!,
            hosts: ["api.github.com", "github.com", "release-assets.githubusercontent.com"],
            version: { HarnessVersionPolicy.latestVersion(provider: .copilot, data: $0) },
            addresses: {
                let base = "https://github.com/github/copilot-cli/releases/download/v\($0)/"
                return (base + "copilot-\(platform).tar.gz", base + "SHA256SUMS.txt")
            },
            expectation: { release, data in expectation(sha256: listedDigest(of: release.artifact.lastPathComponent, in: data)) },
            verify: { _, executable in try CopilotExecutableTrust.verifySignature(executable) })
    }()
}
