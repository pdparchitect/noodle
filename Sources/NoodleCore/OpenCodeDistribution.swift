import Foundation

extension HarnessDistribution {
    /// As https://opencode.ai/v2/install reads it: OpenCode names the version, and
    /// the platform package comes from the npm registry, whose metadata carries
    /// the tarball's SHA-512.
    static let openCode: HarnessDistribution = {
        let package = isAppleSilicon ? "cli-darwin-arm64" : "cli-darwin-x64"
        let registry = "https://registry.npmjs.org/@opencode"
        return HarnessDistribution(
            provider: .openCode, executablePath: "package/bin/opencode", isArchive: true,
            latest: URL(string: "https://opencode.ai/update/api/latest/cli/npm")!,
            hosts: ["opencode.ai", "registry.npmjs.org"],
            version: { HarnessVersionPolicy.latestVersion(provider: .openCode, data: $0) },
            addresses: { ("\(registry)/\(package)/-/\(package)-\($0).tgz", "\(registry)%2f\(package)/\($0)") },
            expectation: { release, data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["version"] as? String == release.version, let dist = object["dist"] as? [String: Any],
                      (dist["tarball"] as? String).flatMap(URL.init(string:)) == release.artifact else { return nil }
                return expectation(integrity: dist["integrity"] as? String)
            },
            verify: { _, executable in try OpenCodeExecutableTrust.verifySignature(executable) })
    }()
}
