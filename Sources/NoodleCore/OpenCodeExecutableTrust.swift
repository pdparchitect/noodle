import Foundation

public enum OpenCodeExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let expected = home.appendingPathComponent(".opencode/bin/opencode").standardizedFileURL
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        guard requested == expected, requested.resolvingSymlinksInPath() == expected,
              FileManager.default.isExecutableFile(atPath: expected.path) else {
            throw HarnessSetupError("OpenCode requires its official v2 native installation at ~/.opencode/bin/opencode, without redirects.")
        }
        try verifySignature(expected)
        return expected
    }

    static func verifySignature(_ executable: URL) throws {
        // Official @opencode/cli-darwin-arm64 2.0.7, also used by the v2 installer.
        try HarnessSignatureVerification.verify(executable,
            requirement: "anchor apple generic and identifier \"opencode\" and certificate leaf[subject.OU] = \"5NZ4Q7NXJ4\"",
            signatureName: "OpenCode’s Anomaly Innovations signature")
    }
}
