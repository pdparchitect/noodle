import Foundation
import ProductIdentity

public enum CopilotProtocol {
    /// Copilot names its models only in a session, and only those its plan offers.
    /// Never return account metadata, tokens, machine details, or raw errors.
    public static func models(fromSession result: [String: Any]) -> [HarnessModel] {
        guard let state = result["models"] as? [String: Any],
              let entries = state["availableModels"] as? [[String: Any]] else { return [] }
        var seen: Set<String> = []
        return entries.compactMap { entry in
            // Copilot lists Auto twice, once as a choice and once with its plan details.
            guard let id = entry["modelId"] as? String, FxProtocol.validIdentifier(id), seen.insert(id).inserted else { return nil }
            return HarnessModel(id: id, displayName: entry["name"] as? String ?? id,
                                description: entry["description"] as? String ?? "Available through Copilot.",
                                supportedEfforts: [], defaultEffort: "", isDefault: id == state["currentModelId"] as? String)
        }
    }

    /// Signed out, Copilot refuses to open a session.
    public static func authenticationRequired(_ error: [String: Any]) -> Bool {
        error["code"] as? Int == -32000 && error["message"] as? String == "Authentication required"
    }

    public static let authenticationFailureDescription = "Copilot needs you to sign in again. Choose Kick for sign-in options. Your session and unfinished work are preserved."

    /// A missing saved session needs confirmed context recovery, not a reconnect.
    public static func missingSession(_ error: [String: Any], sessionID: String) -> Bool {
        error["code"] as? Int == -32002 && error["message"] as? String == "Resource not found: Session \(sessionID) not found"
    }

    public static let missingSessionDescription = "Copilot could not find this bot's saved session. Choose Kick to recover using conversation history. \(ProductIdentity.current.name) will ask before replacing the session. Automatic retries are paused; unfinished work is preserved."

    /// Copilot ends a turn whose model request failed as if it finished, with the error as a reply chunk of
    /// its own: no message ID, starting "Error: ". Nil for anything else, including a reply that mentions one.
    public static func turnFailure(fromUpdate update: [String: Any]) -> String? {
        guard update["sessionUpdate"] as? String == "agent_message_chunk", update["messageId"] == nil,
              let text = (update["content"] as? [String: Any])?["text"] as? String, text.hasPrefix("Error: ") else { return nil }
        return text
    }

    /// GitHub's words for each of Copilot's rate limits, as its service and the CLI put them.
    public static func isUsageLimit(_ failure: String) -> Bool {
        ["hit a rate limit", "hit your rate limit", "hit the rate limit for this model", "hit your session rate limit",
         "reached your weekly rate limit"].contains { failure.localizedCaseInsensitiveContains($0) }
    }

    public static let usageLimitDetail = "Copilot's usage limit has been reached. The bot resumes by itself once usage is available again. Unfinished work is preserved."

    public static let turnFailureDescription = "Copilot could not complete the turn. Check its account and model, then use Kick in Settings → Harness. Unfinished work is preserved."

    /// When the limit lifts, where Copilot says: "Please try again in 4 minutes" or
    /// "wait for your limit to reset on April 19, 2026 at 9:00 PM". Nil when it does not.
    public static func usageLimitReset(_ failure: String, now: Date = Date()) -> Date? {
        if let match = failure.range(of: #"try again in (\d+) (second|minute|hour|day)s?\b"#, options: [.regularExpression, .caseInsensitive]) {
            let words = failure[match].split(separator: " ")
            guard let count = Double(words[3]) else { return nil }
            let unit: Double = switch words[4].lowercased().prefix(3) { case "sec": 1; case "min": 60; case "hou": 3600; default: 86_400 }
            return now.addingTimeInterval(count * unit)
        }
        guard let match = failure.range(of: #"reset on [A-Z][a-z]+ \d{1,2}, \d{4} at \d{1,2}:\d{2} [AP]M"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return formatter.date(from: String(failure[match].dropFirst("reset on ".count)))
    }

    /// The GitHub login Copilot signed in last, from its configuration file, which starts with comments.
    /// Named with its server when that is not github.com. Nothing else in the file is read.
    public static func accountName(fromConfig data: Data) -> String? {
        let text = String(decoding: data.prefix(1_048_576), as: UTF8.self).components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let user = object["lastLoggedInUser"] as? [String: Any] ?? (object["loggedInUsers"] as? [[String: Any]])?.first,
              let login = HarnessAccountName.from(user["login"]) else { return nil }
        guard let host = (user["host"] as? String).flatMap(URL.init(string:))?.host, host != "github.com" else { return login }
        return HarnessAccountName.from("\(login) on \(host)")
    }

    /// `copilot login --device-code` prints the page and the code on one line.
    /// A streaming read can end midway through a line; only whole lines count.
    public static func loginChallenge(_ text: String) -> HarnessSignInChallenge? {
        for line in text.components(separatedBy: .newlines).dropLast() {
            let words = line.split(separator: " ").map(String.init)
            guard let visit = words.firstIndex(of: "visit"), visit + 1 < words.count,
                  let code = words.last, words.dropLast().last == "code",
                  let challenge = HarnessProfileLogin.challenge(provider: .copilot, url: words[visit + 1], code: code) else { continue }
            return challenge
        }
        return nil
    }
}

public enum CopilotLaunch {
    /// Copilot otherwise downloads newer versions of its package and runs those
    /// instead of the one in the executable whose signature was checked.
    public static let environment = ["COPILOT_AUTO_UPDATE": "false"]

    /// Where Copilot unpacks the package inside its executable: one folder in the app's
    /// storage for every login, instead of one in each login's home.
    public static func cacheHome(root: URL) -> URL {
        AgentStorageLayout.canonicalURL(root).appendingPathComponent("Caches/copilot", isDirectory: true)
    }

    /// Unpacks the executable's package into `cacheHome` and returns its folder, which a
    /// restricted bot reads in place of its own copy of about 300 MB.
    public static func package(executable: URL, cacheHome: URL, environment: [String: String]) throws -> URL {
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = environment.merging(Self.environment) { _, fixed in fixed }
            .merging(["COPILOT_CACHE_HOME": cacheHome.path]) { _, cache in cache }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try FileManager.default.createDirectory(at: cacheHome, withIntermediateDirectories: true)
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(4096), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, let version = HarnessVersion.parseOutput(text) else {
            throw HarnessSetupError("Copilot did not report its version. Check copilot in Terminal.")
        }
        let folder = cacheHome.appendingPathComponent("pkg/darwin-arm64/\(version.text)", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              AgentStorageLayout.canonicalURL(folder).path == folder.path,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.js").path) else {
            throw HarnessSetupError("Copilot did not unpack its package. Check copilot in Terminal.")
        }
        return folder
    }
}

/// An account/catalogue-only ACP exchange. Called by the signed host; Noodle receives only the sanitized result.
public enum CopilotInspection {
    /// `managed` is the copy Noodle installed, already verified by the caller,
    /// and is used when the user has no installation of their own, or chose it over theirs.
    public static func inspect(home: URL, environment: [String: String], managed: URL? = nil, prefersManaged: Bool = false) throws -> CopilotInspectionResult {
        let path = home.appendingPathComponent(".local/bin/copilot").path
        guard !(prefersManaged && managed != nil), FileManager.default.isExecutableFile(atPath: path) else {
            guard let managed else { return .init(executablePath: nil, authenticated: false, models: []) }
            return try inspect(executable: managed, installationPath: managed.path, environment: environment)
        }
        let executable = try CopilotExecutableTrust.executable(at: path, home: home)
        return try inspect(executable: executable, installationPath: path, environment: environment)
    }

    // Exercise the protocol with a local fixture; the public entry point always verifies the installation.
    static func inspect(executable: URL, installationPath: String, environment: [String: String],
                        requestTimeout: TimeInterval = 30, terminationGrace: TimeInterval = 2) throws -> CopilotInspectionResult {
        let wire = try ACPInspectionWire(name: "Copilot", command: "copilot", executable: executable, arguments: ["--acp"],
                                         environment: environment.merging(CopilotLaunch.environment) { _, fixed in fixed },
                                         requestTimeout: requestTimeout, terminationGrace: terminationGrace)
        defer { wire.stop() }
        let initialization = try wire.request(1, "initialize", FxProtocol.initializeParameters)
        guard (initialization?["result"] as? [String: Any])?["protocolVersion"] as? Int == 1 else {
            throw HarnessSetupError("Copilot returned an unsupported ACP version.")
        }
        // The only way to read its models; the session is never prompted.
        let session = try wire.request(2, "session/new", ["cwd": FileManager.default.temporaryDirectory.path, "mcpServers": []])
        if let error = session?["error"] as? [String: Any] {
            guard CopilotProtocol.authenticationRequired(error) else {
                throw HarnessSetupError("Copilot could not open a session. Check copilot in Terminal.")
            }
            return .init(executablePath: installationPath, authenticated: false, models: [])
        }
        return .init(executablePath: installationPath, authenticated: true,
                     models: CopilotProtocol.models(fromSession: session?["result"] as? [String: Any] ?? [:]))
    }
}

public struct CopilotInspectionResult: Codable, Sendable {
    public let executablePath: String?
    public let authenticated: Bool
    public let models: [HarnessModel]
    public init(executablePath: String?, authenticated: Bool, models: [HarnessModel]) {
        self.executablePath = executablePath
        self.authenticated = authenticated
        self.models = models
    }
}
