import Foundation

/// Only the layout Devin's own installer makes: ~/.local/bin/devin linking to one
/// version folder of ~/.local/share/devin/cli/_versions, signed by Cognition's Exafunction.
public enum DevinExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let officialLink = home.appendingPathComponent(".local/bin/devin").standardizedFileURL
        guard URL(fileURLWithPath: path).standardizedFileURL == officialLink else {
            throw HarnessSetupError("Devin requires its official installation at ~/.local/bin/devin.")
        }
        let executable = officialLink.resolvingSymlinksInPath()
        let version = DevinLaunch.package(executable: executable)
        let versions = home.appendingPathComponent(".local/share/devin/cli/_versions", isDirectory: true).resolvingSymlinksInPath()
        guard executable.lastPathComponent == "devin", executable.deletingLastPathComponent().lastPathComponent == "bin",
              version.deletingLastPathComponent().standardizedFileURL == versions.standardizedFileURL,
              HarnessVersion(version.lastPathComponent)?.text == version.lastPathComponent,
              executable.resolvingSymlinksInPath() == executable.standardizedFileURL else {
            throw HarnessSetupError("The Devin installation layout is unsupported or redirected.")
        }
        try verifySignature(executable)
        return executable
    }

    public static func verifySignature(_ url: URL) throws {
        let rule = "anchor apple generic and identifier \"devin\" and certificate leaf[subject.OU] = \"83Z2LHX6XW\""
        try HarnessSignatureVerification.verify(url, requirement: rule, signatureName: "Devin’s Cognition signature")
    }
}
