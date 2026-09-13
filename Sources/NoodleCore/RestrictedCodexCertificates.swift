import Foundation
import Security

/// Export public trust anchors before entering the restricted process sandbox.
/// Codex's native certificate discovery needs SecurityServer; giving the agent
/// that service would also expose Keychain APIs. The runtime directory is readable
/// by the harness, but only Noodle's trusted host can replace this certificate file.
public enum RestrictedCodexCertificates {
    public static func prepare(workspace: URL, anchors: () throws -> [Data] = systemAnchors) throws -> URL {
        let certificates = try anchors()
        guard !certificates.isEmpty, certificates.count <= 2048,
              certificates.allSatisfy({ !$0.isEmpty && $0.count <= 65_536 &&
                  SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else {
            throw HarnessSetupError("Could not prepare macOS's public certificates for restricted Codex.")
        }
        let pem = certificates.map { certificate in
            "-----BEGIN CERTIFICATE-----\n" + certificate.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) +
                "\n-----END CERTIFICATE-----\n"
        }.joined()
        guard pem.utf8.count <= 4_194_304 else {
            throw HarnessSetupError("The macOS public certificate bundle is too large for restricted Codex.")
        }
        let package = AgentStorageLayout(workspace: workspace).package
        let runtime = try WorkspaceMailbox(workspace: package, path: "runtime")
        let filename = "codex-ca-certificates.pem"
        try runtime.writeData(Data(pem.utf8), named: filename)
        return package.appendingPathComponent("runtime/" + filename)
    }

    public static func systemAnchors() throws -> [Data] {
        var anchors: CFArray?
        let status = SecTrustCopyAnchorCertificates(&anchors)
        guard status == errSecSuccess, let certificates = anchors as? [SecCertificate], !certificates.isEmpty else {
            throw HarnessSetupError("Could not read macOS's public trust certificates for restricted Codex (\(status)).")
        }
        return certificates.map { SecCertificateCopyData($0) as Data }
    }
}
