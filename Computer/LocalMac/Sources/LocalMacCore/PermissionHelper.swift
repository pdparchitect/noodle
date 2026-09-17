import Foundation

/// Settings resolves a helper nested inside another app to its enclosing app.
/// Provide a standalone, signed copy that the owner can select in Settings,
/// without exposing the managed account's private home or launching any code.
public enum LocalMacPermissionHelper {
    public static func prepare(source: URL, directory: URL, providerID: String, team: String) throws -> URL {
        guard let identity = LocalMacIdentity(providerID: providerID), identity.permitsAccountService,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              Bundle(url: source)?.bundleIdentifier == identity.desktopID else {
            throw LocalMacError("The desktop helper does not match this Computer app.")
        }
        let requirement = "anchor apple generic and identifier \"\(identity.desktopID)\" and certificate leaf[subject.OU] = \"\(team)\""
        // Verify before creating anything. The atomic installer also checks the
        // copied image and requires its CDHash to match this exact signed build.
        _ = try LocalMacSignedCode.fingerprint(at: source, requirement: requirement)
        let directory = directory.standardizedFileURL
        guard directory.resolvingSymlinksInPath() == directory,
              !directory.pathComponents.contains(where: { $0.hasSuffix(".app") }) else {
            throw LocalMacError("Choose a standalone folder for the desktop permission helper.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(identity.desktopAppName + ".app", isDirectory: true)
        try LocalMacRuntimeUpdate.install(source: source, destination: destination) {
            try LocalMacSignedCode.fingerprint(at: $0, requirement: requirement)
        }
        return destination
    }
}
