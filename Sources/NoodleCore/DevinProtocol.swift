import Foundation
import ProductIdentity

public enum DevinProtocol {
    /// Devin names its models only in a session, as the choices of its "model" option.
    /// Never return account metadata, tokens, machine details, or raw errors.
    public static func models(fromSession result: [String: Any]) -> [HarnessModel] {
        guard let option = modelOption(result), let entries = option["options"] as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard let id = entry["value"] as? String, FxProtocol.validIdentifier(id), seen.insert(id).inserted else { return nil }
            return HarnessModel(id: id, displayName: entry["name"] as? String ?? id, description: "Available through Devin.",
                                supportedEfforts: [], defaultEffort: "", isDefault: id == option["currentValue"] as? String)
        }
    }

    /// The model a session opened with, when no model was chosen for it.
    public static func currentModel(fromSession result: [String: Any]) -> String? {
        (modelOption(result)?["currentValue"] as? String).flatMap { FxProtocol.validIdentifier($0) ? $0 : nil }
    }

    private static func modelOption(_ result: [String: Any]) -> [String: Any]? {
        (result["configOptions"] as? [[String: Any]])?.first { $0["id"] as? String == "model" }
    }

    /// Without a login Devin opens a session and refuses its first prompt; with a login its
    /// service rejects, it refuses the session.
    public static func authenticationRequired(_ error: [String: Any]) -> Bool {
        guard error["code"] as? Int == -32000, let message = error["message"] as? String else { return false }
        return message.hasPrefix("Please log in") || message.hasPrefix("Authentication failed")
    }

    public static let authenticationFailureDescription = "Devin needs you to sign in again. Choose Kick for sign-in options. Your session and unfinished work are preserved."
}

public enum DevinLaunch {
    /// In its own process: otherwise Devin hands sessions to a background daemon shared
    /// by every `devin` command, outside the bot's process group and sandbox.
    public static let arguments = ["acp", "--process-model", "in-process"]

    /// Its configuration file, relative to a home Noodle keeps for it. Devin otherwise
    /// downloads newer versions of itself into that home.
    static let configurationPath = ".config/devin"
    static let configuration = Data(#"{"auto_update": false}"#.utf8 + [10])

    /// Writes the configuration into a home Noodle keeps for Devin, which adds its own settings beside it.
    static func prepareConfiguration(home: URL) throws {
        let folder = home.appendingPathComponent(configurationPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try AtomicFile.write(configuration, to: folder.appendingPathComponent("config.json"))
    }

    /// The version folder the executable runs from, with the tools beside it.
    public static func package(executable: URL) -> URL {
        executable.deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// An account/catalogue-only ACP exchange. Called by the signed host; Noodle receives only the sanitized result.
public enum DevinInspection {
    /// `managed` is the copy Noodle installed, already verified by the caller,
    /// and is used when the user has no installation of their own, or chose it over theirs.
    public static func inspect(home: URL, environment: [String: String], managed: URL? = nil, prefersManaged: Bool = false) throws -> DevinInspectionResult {
        let path = home.appendingPathComponent(".local/bin/devin").path
        guard !(prefersManaged && managed != nil), FileManager.default.isExecutableFile(atPath: path) else {
            guard let managed else { return .init(executablePath: nil, authenticated: false, models: []) }
            return try inspect(executable: managed, installationPath: managed.path, environment: environment)
        }
        let executable = try DevinExecutableTrust.executable(at: path, home: home)
        return try inspect(executable: executable, installationPath: path, environment: environment)
    }

    // Exercise the protocol with a local fixture; the public entry point always verifies the installation.
    static func inspect(executable: URL, installationPath: String, environment: [String: String],
                        requestTimeout: TimeInterval = 30, terminationGrace: TimeInterval = 2) throws -> DevinInspectionResult {
        let wire = try ACPInspectionWire(name: "Devin", command: "devin", executable: executable, arguments: DevinLaunch.arguments,
                                         environment: environment, requestTimeout: requestTimeout, terminationGrace: terminationGrace)
        defer { wire.stop() }
        let initialization = try wire.request(1, "initialize", FxProtocol.initializeParameters)
        guard (initialization?["result"] as? [String: Any])?["protocolVersion"] as? Int == 1 else {
            throw HarnessSetupError("Devin returned an unsupported ACP version.")
        }
        // The only way to read its models. The session is never prompted, so Devin does not keep it.
        let session = try wire.request(2, "session/new", ["cwd": FileManager.default.temporaryDirectory.path, "mcpServers": []])
        if let error = session?["error"] as? [String: Any] {
            guard DevinProtocol.authenticationRequired(error) else {
                throw HarnessSetupError("Devin could not open a session. Check devin in Terminal.")
            }
            return .init(executablePath: installationPath, authenticated: false, models: [])
        }
        // Signed out, the session offers no models.
        let models = DevinProtocol.models(fromSession: session?["result"] as? [String: Any] ?? [:])
        return .init(executablePath: installationPath, authenticated: !models.isEmpty, models: models)
    }
}

public struct DevinInspectionResult: Codable, Sendable {
    public let executablePath: String?
    public let authenticated: Bool
    public let models: [HarnessModel]
    public init(executablePath: String?, authenticated: Bool, models: [HarnessModel]) {
        self.executablePath = executablePath
        self.authenticated = authenticated
        self.models = models
    }
}

/// Devin's own browser sign-in, through its ACP server: it opens Devin's page in the browser
/// itself and answers once the person signed in, saving the login in the home it was given.
/// Its `auth login` command needs a terminal the Agent Host does not have.
public final class DevinSignIn: @unchecked Sendable {
    private let executable: URL
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var wire: ACPInspectionWire?
    private var cancelled = false

    public init(executable: URL, environment: [String: String], timeout: TimeInterval = 600) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
    }

    /// Blocks until the person signed in, the sign-in failed, or it was cancelled.
    public func run() throws {
        let wire = try ACPInspectionWire(name: "Devin", command: "devin", executable: executable, arguments: DevinLaunch.arguments,
                                         environment: environment, requestTimeout: timeout, terminationGrace: 2, opensPages: true)
        lock.lock()
        guard !cancelled else { lock.unlock(); wire.stop(); throw CancellationError() }
        self.wire = wire
        lock.unlock()
        defer { wire.stop() }
        let initialization = try wire.request(1, "initialize", FxProtocol.initializeParameters)
        guard (initialization?["result"] as? [String: Any])?["protocolVersion"] as? Int == 1 else {
            throw HarnessSetupError("Devin returned an unsupported ACP version.")
        }
        let answer = try wire.request(2, "authenticate", ["methodId": "devin-browser"])
        guard answer?["error"] == nil else { throw HarnessSetupError("Devin sign-in did not complete. Try signing in again.") }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let wire = self.wire
        lock.unlock()
        wire?.interrupt()
    }
}
