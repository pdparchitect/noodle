import Foundation
import Security

public enum FxExecutableTrust {
    public static func executable(at path: String, home: URL) throws -> URL {
        let expected = home.appendingPathComponent(".local/bin/fx").standardizedFileURL
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url == expected, url.resolvingSymlinksInPath() == url else {
            throw HarnessSetupError("FX requires its official native installation at ~/.local/bin/fx, without redirects.")
        }
        let rule = "anchor apple generic and identifier \"com.vercel.fx\" and certificate leaf[subject.OU] = \"JW6Y669B67\""
        try HarnessSignatureVerification.verify(url, requirement: rule, signatureName: "FX’s Vercel signature")
        return url
    }
}
