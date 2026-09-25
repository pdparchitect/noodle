import Foundation

public enum HarnessAuthenticationStatus: String, Codable, Equatable, Sendable {
    case authenticated, unauthenticated, notRequired, managedExternally
}

public struct HarnessSignInChallenge: Equatable, Sendable {
    public let url: URL
    public let code: String
}

public struct HarnessInstallationGuide: Equatable, Sendable {
    public let command: String?
    public let instructions: String
    public let documentationURL: URL

    public init(command: String?, instructions: String, documentationURL: URL) {
        self.command = command
        self.instructions = instructions
        self.documentationURL = documentationURL
    }
}

public struct HarnessSetupError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Provider-specific setup stays behind this interface, not in Settings.
@MainActor public protocol HarnessSetupProviding {
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus
    var installationGuide: HarnessInstallationGuide { get }
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus
}

public enum HarnessStorage {
    public static var userHome: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    public static var codexHome: URL { userHome.appendingPathComponent(".codex") }
}

@MainActor public final class CodexSetupProvider: HarnessSetupProviding {
    private let codexHome: URL
    private let environment: [String: String]?
    /// The Agent Host passes its own fixed environment; the app uses its own.
    public init(codexHome: URL, environment: [String: String]? = nil) {
        self.codexHome = codexHome
        self.environment = environment
    }

    /// A sign-in page relayed by the Agent Host is held to the same rule as one read directly.
    nonisolated public static func relayedChallenge(url: String, code: String) -> HarnessSignInChallenge? {
        try? CodexAccountResponse.challenge(["type": "chatgptDeviceCode", "verificationUrl": url, "userCode": code])
    }

    public func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try await session(for: installation).run()
    }

    public func signIn(for installation: HarnessInstallation,
                       onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        try await session(for: installation).run(onChallenge: onChallenge)
    }

    /// Spends the login's refresh token now, the way Codex would on its own.
    public func refresh(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        try await session(for: installation, refresh: true).run()
    }

    public var installationGuide: HarnessInstallationGuide {
        HarnessInstallationGuide(
            command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
            instructions: "Run OpenAI’s official installer in Terminal, then return here and check the installation. It installs Codex outside Noodle, available to other apps and your shell. Follow any prompts shown by the installer.",
            documentationURL: URL(string: "https://learn.chatgpt.com/docs/codex/cli")!
        )
    }

    private func session(for installation: HarnessInstallation, refresh: Bool = false) throws -> CodexAccountSession {
        guard installation.provider == .codex, let path = installation.executablePath else {
            throw HarnessSetupError("Install the harness first.")
        }
        return CodexAccountSession(executableURL: URL(fileURLWithPath: path), codexHome: codexHome, environment: environment, refresh: refresh)
    }
}

/// Codex refreshes a login shortly before its access token lapses, ten days after
/// the last refresh. Every bot on the login lapses at once and would race to spend
/// the one refresh token, so Noodle refreshes it first, once for all of them.
public enum CodexLoginRefresh {
    public static let age: TimeInterval = 7 * 86_400

    /// Reads only the refresh time, never a token.
    public static func isDue(_ auth: Data, now: Date = Date()) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: auth) as? [String: Any], json["tokens"] is [String: Any],
              let text = json["last_refresh"] as? String, text.count >= 19,
              let refreshed = ISO8601DateFormatter().date(from: text.prefix(19) + "Z") else { return false }
        return now.timeIntervalSince(refreshed) >= age
    }
}

/// Interpret account metadata only. Never open auth.json or expose tokens.
enum CodexAccountResponse {
    static func status(_ result: [String: Any]) throws -> HarnessAuthenticationStatus {
        if let account = result["account"] as? [String: Any], account["type"] is String {
            return .authenticated
        }
        guard result["account"] is NSNull, let required = result["requiresOpenaiAuth"] as? Bool else {
            throw HarnessSetupError("The harness returned an unsupported account response.")
        }
        return required ? .unauthenticated : .notRequired
    }

    static func challenge(_ result: [String: Any]) throws -> HarnessSignInChallenge {
        guard result["type"] as? String == "chatgptDeviceCode",
              let rawURL = result["verificationUrl"] as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host == "auth.openai.com",
              url.path == "/codex/device", url.user == nil, url.password == nil, url.port == nil,
              let code = result["userCode"] as? String, !code.isEmpty, code.count <= 64 else {
            throw HarnessSetupError("The harness returned an unsupported sign-in response.")
        }
        return HarnessSignInChallenge(url: url, code: code)
    }
}

/// A short-lived account-only app-server connection. No thread or turn is created.
@MainActor private final class CodexAccountSession {
    private let executableURL: URL
    private let codexHome: URL
    private let baseEnvironment: [String: String]?
    private var process: Process?
    private var input: ProcessInputWriter?
    private var output: FileHandle?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<HarnessAuthenticationStatus, Error>?
    private var onChallenge: (@MainActor (HarnessSignInChallenge) -> Void)?
    private var loginID: String?
    private var loginCompleted = false
    private lazy var reader = JSONLineReader { [weak self] message in
        Task { @MainActor in self?.receive(message) }
    }

    private let refresh: Bool

    init(executableURL: URL, codexHome: URL, environment: [String: String]? = nil, refresh: Bool = false) {
        self.executableURL = executableURL
        self.codexHome = codexHome
        baseEnvironment = environment
        self.refresh = refresh
    }

    func run(onChallenge: (@MainActor (HarnessSignInChallenge) -> Void)? = nil) async throws -> HarnessAuthenticationStatus {
        self.onChallenge = onChallenge
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
                    child.executableURL = executableURL
                    child.arguments = CodexLaunch.appServerArguments()
                    child.currentDirectoryURL = FileManager.default.temporaryDirectory
                    var environment = baseEnvironment ?? ProcessInfo.processInfo.environment
                    environment["CODEX_HOME"] = codexHome.path
                    child.environment = environment
                    child.standardInput = stdinPipe
                    // Cancellation can race a queued write. Configure this valid
                    // pipe before use so a closed child reports EPIPE, not SIGPIPE.
                    _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    child.standardOutput = stdoutPipe
                    // Account failures are reported through JSON-RPC. Do not retain
                    // arbitrary stderr, which may include private configuration.
                    child.standardError = FileHandle.nullDevice
                    let reader = reader
                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty { handle.readabilityHandler = nil }
                        else { reader.receive(data) }
                    }
                    child.terminationHandler = { [weak self] _ in
                        Task { @MainActor in
                            self?.finish(.failure(HarnessSetupError("The harness stopped before setup completed. Try again.")))
                        }
                    }
                    output = stdoutPipe.fileHandleForReading
                    try child.run()
                    process = child
                    input = ProcessInputWriter(handle: stdinPipe.fileHandleForWriting)
                    send("initialize", id: 1, params: ["clientInfo": ["name": "noodle", "version": "1"], "capabilities": [:]])
                    setTimeout(seconds: 15)
                } catch { finish(.failure(HarnessSetupError("Could not start the harness to check its account. Check the installation and try again."))) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func receive(_ message: [String: Any]) {
        guard continuation != nil else { return }
        if let id = message["id"] as? Int {
            if let error = message["error"] {
                // A login that can no longer be read, such as one whose refresh
                // token was spent, must not stop the user from signing in again.
                if id == 2, onChallenge != nil, !loginCompleted {
                    send("account/login/start", id: 3, params: ["type": "chatgptDeviceCode"])
                    setTimeout(seconds: 30)
                    return
                }
                var detail = id == 3
                    ? "Sign-in could not start. Enable device-code login in your ChatGPT account or workspace settings, or sign in using Codex and check again."
                    : "Could not check sign-in status. Check the harness configuration and account access, then try again."
                if let reason = ((error as? [String: Any])?["message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                    detail += " Codex reported: \(reason.prefix(300))"
                }
                finish(.failure(HarnessSetupError(detail)))
                return
            }
            guard let result = message["result"] as? [String: Any] else {
                finish(.failure(HarnessSetupError("The harness returned an unsupported setup response.")))
                return
            }
            do {
                switch id {
                case 1:
                    send("initialized")
                    send("account/read", id: 2, params: ["refreshToken": refresh])
                case 2:
                    let status = try CodexAccountResponse.status(result)
                    // Codex reads a stored login as signed in even when the server has
                    // revoked it, so an explicit sign-in always starts a new one.
                    if onChallenge != nil, !loginCompleted {
                        send("account/login/start", id: 3, params: ["type": "chatgptDeviceCode"])
                        setTimeout(seconds: 30)
                    } else { finish(.success(status)) }
                case 3:
                    guard let id = result["loginId"] as? String, !id.isEmpty else {
                        throw HarnessSetupError("The harness did not identify the sign-in attempt.")
                    }
                    loginID = id
                    let challenge = try CodexAccountResponse.challenge(result)
                    setTimeout(seconds: 600)
                    onChallenge?(challenge)
                default: break
                }
            } catch { finish(.failure(error)) }
        } else if message["method"] as? String == "account/login/completed",
                  let params = message["params"] as? [String: Any],
                  let expected = loginID, params["loginId"] as? String == expected {
            if params["success"] as? Bool == true {
                loginCompleted = true
                loginID = nil
                send("account/read", id: 2, params: ["refreshToken": false])
                setTimeout(seconds: 15)
            } else {
                finish(.failure(HarnessSetupError("Sign-in did not complete or expired. Try again.")))
            }
        }
    }

    private func send(_ method: String, id: Int? = nil, params: [String: Any] = [:]) {
        var message: [String: Any] = ["method": method, "params": params]
        if let id { message["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        input?.write(data + Data([10])) { [weak self] _ in
            Task { @MainActor in self?.finish(.failure(HarnessSetupError("The harness connection closed. Try again."))) }
        }
    }

    private func setTimeout(seconds: Double) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(HarnessSetupError("The harness setup request timed out. Try again.")))
        }
    }

    private func finish(_ result: Result<HarnessAuthenticationStatus, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let loginID { send("account/login/cancel", id: 4, params: ["loginId": loginID]) }
        loginID = nil
        timeout?.cancel()
        timeout = nil
        output?.readabilityHandler = nil
        output = nil
        input = nil
        if let child = process {
            child.terminationHandler = nil
            if child.isRunning {
                child.terminate()
                Task.detached {
                    try? await Task.sleep(for: .seconds(1))
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
        self.onChallenge = nil
        continuation.resume(with: result)
    }
}
