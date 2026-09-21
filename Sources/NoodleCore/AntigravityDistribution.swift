import Foundation

extension HarnessDistribution {
    /// As https://antigravity.google/cli/install.sh reads it: one manifest names
    /// the version, the archive in Google's release bucket, and its SHA-512.
    static let antigravity: HarnessDistribution = {
        let manifest = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_arm64.json"
        let bucket = "https://storage.googleapis.com/antigravity-public/antigravity-cli/"
        let field: @Sendable (Data, String) -> String? = { data, name in
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[name] as? String
        }
        return HarnessDistribution(
            provider: .antigravity, executablePath: "antigravity", isArchive: true,
            latest: URL(string: manifest)!,
            hosts: ["antigravity-cli-auto-updater-974169037036.us-central1.run.app", "storage.googleapis.com"],
            version: { HarnessVersionPolicy.latestVersion(provider: .antigravity, data: $0) },
            addresses: { _ in ("", manifest) },
            expectation: { release, data in
                // The manifest is read twice; both reads must describe the same release.
                guard HarnessVersionPolicy.latestVersion(provider: .antigravity, data: data) == release.version,
                      field(data, "url").flatMap(URL.init(string:)) == release.artifact,
                      let digest = field(data, "sha512")?.lowercased(),
                      digest.range(of: #"^[0-9a-f]{128}$"#, options: .regularExpression) != nil else { return nil }
                return Expectation(algorithm: .sha512, digest: digest, byteCount: nil)
            },
            verify: { _, executable in try AntigravityExecutableTrust.verifySignature(executable) },
            // Anyone can publish to the shared storage host; only Google's bucket is accepted.
            artifact: { data in field(data, "url").flatMap { $0.hasPrefix(bucket) ? $0 : nil } })
    }()
}
