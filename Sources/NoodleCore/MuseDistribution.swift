import Foundation

extension HarnessDistribution {
    /// As Meta's launcher reads it: the stable channel names a version, whose
    /// release manifest lists one native executable per platform with its
    /// SHA-256 and size. Noodle keeps that executable alone, without the
    /// self-updating shell launcher the Agent Host refuses to run anyway.
    static let muse: HarnessDistribution = {
        let platform = isAppleSilicon ? "aarch64" : "x86"
        let base = "https://lookaside.facebook.com/lookaside/muse/download/?channel=muse&version="
        return HarnessDistribution(
            provider: .muse, executablePath: "muse", isArchive: false,
            latest: URL(string: "https://api.meta.ai/muse-code/channels/muse-stable")!,
            hosts: ["api.meta.ai", "lookaside.facebook.com"],
            version: { HarnessVersionPolicy.latestVersion(provider: .muse, data: $0) },
            addresses: { (base + "\($0)&file=muse-\(platform)-macos", base + "\($0)&file=manifest.json") },
            expectation: { release, data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["version"] as? String == release.version, object["checksum_algorithm"] as? String == "sha256",
                      let entry = (object["artifacts"] as? [String: Any])?["\(platform)_macos"] as? [String: Any],
                      // The address is derived here; a manifest that points elsewhere is a layout Noodle does not know.
                      (entry["url"] as? String).flatMap(URL.init(string:)) == release.artifact else { return nil }
                return expectation(sha256: entry["checksum"] as? String, byteCount: (entry["size"] as? NSNumber)?.int64Value)
            },
            verify: { _, executable in try MuseExecutableTrust.verifySignature(executable) })
    }()
}
