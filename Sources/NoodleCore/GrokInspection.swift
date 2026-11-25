import Foundation

/// An account/catalogue-only ACP exchange. No sessions, prompts or tools.
/// Called by the signed host; Noodle receives only the sanitized result.
public enum GrokInspection {
    /// `managed` is the copy Noodle installed, already verified by the caller,
    /// and is used when the user has no installation of their own, or chose it over theirs.
    public static func inspect(home: URL, environment: [String: String], managed: URL? = nil, prefersManaged: Bool = false) throws -> GrokInspectionResult {
        let path = home.appendingPathComponent(".grok/bin/grok").path
        guard !(prefersManaged && managed != nil), FileManager.default.isExecutableFile(atPath: path) else {
            guard let managed else { return .init(executablePath: nil, authenticated: false, models: []) }
            return try inspect(executable: managed, installationPath: managed.path, environment: environment)
        }
        let executable = try GrokExecutableTrust.executable(at: path, home: home)
        return try inspect(executable: executable, installationPath: path, environment: environment)
    }

    // Exercise the protocol with a local fixture; the public entry point always verifies the installation.
    static func inspect(executable: URL, installationPath: String, environment: [String: String],
                        requestTimeout: TimeInterval = 20, terminationGrace: TimeInterval = 2) throws -> GrokInspectionResult {
        let wire = try ACPInspectionWire(name: "Grok Build", command: "grok", executable: executable,
                                         arguments: ["agent", "--no-leader", "stdio"], environment: environment,
                                         requestTimeout: requestTimeout, terminationGrace: terminationGrace)
        defer { wire.stop() }
        let initialization = try wire.request(1, "initialize", FxProtocol.initializeParameters)
        guard let result = initialization?["result"] as? [String: Any], result["protocolVersion"] as? Int == 1 else {
            throw HarnessSetupError("Grok Build returned an unsupported ACP version.")
        }
        // Signed out, grok starts its browser sign-in instead of answering, so silence is signed out.
        let auth = try wire.request(2, "authenticate", ["methodId": "cached_token"], silenceIsAnswer: true)
        return .init(executablePath: installationPath, authenticated: auth?["result"] is [String: Any],
                     models: try GrokProtocol.models(from: result))
    }
}
