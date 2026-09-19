import Foundation

extension HarnessDistribution {
    /// As https://claude.ai/install.sh reads it: a plain version pointer, a
    /// manifest of per-platform checksums, and one executable.
    static let claudeCode: HarnessDistribution = {
        let platform = "darwin-arm64"
        let base = "https://downloads.claude.ai/claude-code-releases/"
        return HarnessDistribution(
            provider: .claudeCode, executablePath: "claude", isArchive: false,
            latest: URL(string: base + "latest")!, hosts: ["downloads.claude.ai"],
            version: { HarnessVersionPolicy.latestVersion(provider: .claudeCode, data: $0) },
            addresses: { (base + "\($0)/\(platform)/claude", base + "\($0)/manifest.json") },
            expectation: { _, data in
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let entry = (object?["platforms"] as? [String: Any])?[platform] as? [String: Any]
                return expectation(sha256: entry?["checksum"] as? String, byteCount: (entry?["size"] as? NSNumber)?.int64Value)
            },
            verify: { _, executable in try ClaudeExecutableTrust.verifySignature(executable) })
    }()
}
