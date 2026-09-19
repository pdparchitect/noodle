import Foundation

extension HarnessDistribution {
    /// As https://fx.sh/setup.sh reads it. Vercel publishes no checksum, so the
    /// signature check in the Agent Host is the only verification.
    static let fx: HarnessDistribution = {
        let platform = "macos-aarch64"
        return HarnessDistribution(
            provider: .fx, executablePath: "fx", isArchive: true,
            latest: URL(string: "https://releases.fx.sh/latest.txt")!, hosts: ["releases.fx.sh"],
            version: { HarnessVersionPolicy.latestVersion(provider: .fx, data: $0) },
            addresses: { ("https://releases.fx.sh/v\($0)/fx-\(platform).tar.gz", nil) },
            expectation: { _, _ in nil },
            verify: { _, executable in try FxExecutableTrust.verifySignature(executable) })
    }()
}
