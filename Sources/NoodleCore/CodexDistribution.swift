import Foundation

extension HarnessDistribution {
    /// As https://chatgpt.com/codex/install.sh reads it: the GitHub release names
    /// the version, and OpenAI's release host serves the package and its checksums.
    static let codex: HarnessDistribution = {
        let platform = "aarch64-apple-darwin"
        return HarnessDistribution(
            provider: .codex, executablePath: "bin/codex", isArchive: true,
            latest: URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!,
            hosts: ["api.github.com", "releases.openai.com"],
            version: { HarnessVersionPolicy.latestVersion(provider: .codex, data: $0) },
            addresses: {
                let base = "https://releases.openai.com/codex/releases/\($0)/"
                return (base + "codex-package-\(platform).tar.gz", base + "codex-package_SHA256SUMS")
            },
            expectation: { release, data in expectation(sha256: listedDigest(of: release.artifact.lastPathComponent, in: data)) },
            verify: { package, executable in
                try CodexExecutableTrust.verifyPackage(package)
                try CodexExecutableTrust.verifySignature(executable, identifier: "codex")
            })
    }()
}
