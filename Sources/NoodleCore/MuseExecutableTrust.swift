import Foundation

public enum MuseExecutableTrust {
    public static func validVersion(_ value: String) -> Bool {
        value.count < 100 && value.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+-R[0-9]+(?:\.[0-9]+)?\z"#,
                                         options: .regularExpression) != nil
    }

    /// The official shell launcher can self-update. Do not execute it in the host:
    /// resolve its small version pointer and verify the native Meta binary instead.
    public static func executable(at path: String, home: URL) throws -> URL {
        let directory = home.appendingPathComponent(".local/bin", isDirectory: true).standardizedFileURL
        let launcher = directory.appendingPathComponent("muse")
        guard URL(fileURLWithPath: path).standardizedFileURL == launcher,
              directory.resolvingSymlinksInPath() == directory,
              launcher.resolvingSymlinksInPath() == launcher else {
            throw HarnessSetupError("Muse Code requires its native installation at ~/.local/bin/muse, without redirects.")
        }
        let pointer = directory.appendingPathComponent(".muse-version")
        guard pointer.resolvingSymlinksInPath() == pointer,
              let size = try? pointer.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128,
              let raw = try? String(contentsOf: pointer, encoding: .utf8) else {
            throw HarnessSetupError("Muse Code’s installed version could not be read. Run its installer in Terminal, then check again.")
        }
        let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validVersion(version) else { throw HarnessSetupError("Muse Code has an unsupported installation version.") }
        let binary = directory.appendingPathComponent("muse-bin-\(version)")
        guard binary.resolvingSymlinksInPath() == binary, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw HarnessSetupError("Muse Code’s native executable is missing or redirected. Run its installer in Terminal.")
        }
        try HarnessSignatureVerification.verify(binary,
            requirement: "anchor apple generic and certificate leaf[subject.OU] = \"V9WTTPBFK9\"",
            signatureName: "Muse Code’s Meta signature")
        return binary
    }
}
