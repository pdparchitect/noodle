import Foundation
import Security

public enum AntigravityExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let expected = home.appendingPathComponent(".local/bin/agy").standardizedFileURL
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url == expected, url.resolvingSymlinksInPath() == url else {
            throw HarnessSetupError("Antigravity requires its official native installation at ~/.local/bin/agy, without redirects.")
        }
        try verifySignature(url)
        return url
    }

    public static func verifySignature(_ url: URL) throws {
        let rule = "anchor apple generic and identifier \"cli\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        try HarnessSignatureVerification.verify(url, requirement: rule, signatureName: "Antigravity’s Google signature")
    }
}
