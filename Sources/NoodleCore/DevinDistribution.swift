import Foundation

extension HarnessDistribution {
    /// As https://cli.devin.ai/install.sh reads it: the current manifest names the version,
    /// and each version's own manifest the archive and its SHA-256. The archive holds the
    /// version folder, with the executable in bin.
    static let devin: HarnessDistribution = {
        let platform = "aarch64-apple-darwin"
        let base = "https://static.devin.ai/cli/"
        return HarnessDistribution(
            provider: .devin, executablePath: "bin/devin", isArchive: true,
            latest: URL(string: base + "current/manifest.json")!, hosts: ["static.devin.ai"],
            version: { HarnessVersionPolicy.latestVersion(provider: .devin, data: $0) },
            addresses: { (base + "\($0)/devin-\($0)-\(platform).tar.gz", base + "\($0)/manifest.json") },
            expectation: { release, data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["version"] as? String == release.version,
                      let entry = (object["platforms"] as? [String: Any])?[platform] as? [String: Any],
                      // The address is derived here; a manifest that points elsewhere is a layout Noodle does not know.
                      (entry["url"] as? String).flatMap(URL.init(string:)) == release.artifact else { return nil }
                return expectation(sha256: entry["sha256"] as? String)
            },
            verify: { _, executable in try DevinExecutableTrust.verifySignature(executable) })
    }()
}
