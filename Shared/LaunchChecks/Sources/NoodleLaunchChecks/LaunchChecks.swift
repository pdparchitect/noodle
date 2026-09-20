import CryptoKit
import Foundation

/// Launch arguments that only verification and development runs pass to an app.
///
/// An argument is recognised by the SHA-256 digest of its text, so its name never appears in a built
/// binary. Write the name beside the digest in source:
///
///     static let updaterUI = "9f2c…"  // --updater-ui-test
///
/// Produce a digest with `printf %s '--updater-ui-test' | shasum -a 256`.
public struct LaunchChecks: Sendable {
    public static let current = LaunchChecks(arguments: CommandLine.arguments)

    private let arguments: [String]
    private let digests: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
        digests = arguments.map(Self.digest)
    }

    public func contains(_ digest: String) -> Bool {
        digests.contains(digest)
    }

    /// The argument that follows the one matching `digest`.
    public func value(after digest: String) -> String? {
        guard let index = digests.firstIndex(of: digest), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    public static func digest(_ argument: String) -> String {
        SHA256.hash(data: Data(argument.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
