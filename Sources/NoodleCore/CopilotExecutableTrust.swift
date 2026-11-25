import Foundation

public enum CopilotExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let expected = home.appendingPathComponent(".local/bin/copilot").standardizedFileURL
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url == expected, url.resolvingSymlinksInPath() == url else {
            throw HarnessSetupError("Copilot requires its official native installation at ~/.local/bin/copilot, without redirects.")
        }
        try verifySignature(url)
        return url
    }

    public static func verifySignature(_ url: URL) throws {
        let rule = "anchor apple generic and identifier \"copilot\" and certificate leaf[subject.OU] = \"VEKTX9H2N7\""
        try HarnessSignatureVerification.verify(url, requirement: rule, signatureName: "Copilot’s GitHub signature")
    }
}
