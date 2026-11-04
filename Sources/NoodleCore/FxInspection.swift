import Foundation

/// A Vercel team FX can send model requests through.
public struct FxTeam: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let slug: String
    public let isSelected: Bool

    public init(name: String, slug: String, isSelected: Bool) {
        self.name = name
        self.slug = slug
        self.isSelected = isSelected
    }
}

/// Fixed FX commands, read-only apart from choosing a team; never returns raw configuration or credentials.
public enum FxInspection {
    public static func status(executable: URL, environment: [String: String]) throws -> (authenticated: Bool, model: String?) {
        let data = try run(executable: executable, arguments: ["status", "--json"], environment: environment)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "status", let auth = object["auth"] as? String else {
            throw HarnessSetupError("FX returned an unsupported account status.")
        }
        return (!auth.isEmpty && auth != "missing", object["model"] as? String)
    }

    public static func models(executable: URL, environment: [String: String]) throws -> [HarnessModel] {
        let current = try status(executable: executable, environment: environment)
        let data = try run(executable: executable, arguments: ["models", "--json"], environment: environment)
        return try FxProtocol.models(from: data, defaultModel: current.model)
    }

    /// `fx teams` has no machine-readable form. It lists the teams and asks for a
    /// number; with no answer it keeps the selected team.
    public static func teams(executable: URL, environment: [String: String]) throws -> [FxTeam] {
        let output = String(decoding: try run(executable: executable, arguments: ["teams"], environment: environment), as: UTF8.self)
        guard let teams = FxProtocol.teams(from: output) else {
            throw HarnessSetupError("FX listed its teams in a way Noodle does not recognize. Choose the team with fx teams in Terminal.")
        }
        return teams
    }

    /// Answers with the team's number in the list as it stands, then checks FX's confirmation.
    public static func selectTeam(_ slug: String, executable: URL, environment: [String: String]) throws -> [FxTeam] {
        let teams = try teams(executable: executable, environment: environment)
        guard let index = teams.firstIndex(where: { $0.slug == slug }) else {
            throw HarnessSetupError("That team is no longer available to this sign-in.")
        }
        let output = String(decoding: try run(executable: executable, arguments: ["teams"], environment: environment,
                                              input: Data("\(index + 1)\n".utf8)), as: UTF8.self)
        guard output.components(separatedBy: .newlines).contains(where: {
            $0.contains("Selected Vercel team: ") && $0.hasSuffix(" (\(slug)).")
        }) else { throw HarnessSetupError("FX did not confirm the team change. Check it with fx teams in Terminal.") }
        return teams.map { FxTeam(name: $0.name, slug: $0.slug, isSelected: $0.slug == slug) }
    }

    private static func run(executable: URL, arguments: [String], environment: [String: String], input: Data? = nil) throws -> Data {
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        BrowserlessLaunch.configure(process, executable: executable, arguments: arguments)
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        if let input {
            // Small enough for the pipe's buffer; written before launch so an early exit cannot raise SIGPIPE here.
            let answer = Pipe()
            try answer.fileHandleForWriting.write(contentsOf: input)
            try answer.fileHandleForWriting.close()
            process.standardInput = answer
        } else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let capture = BoundedOutput()
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        output.fileHandleForWriting.closeFile()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                capture.append(bytes)
            }
            drained.signal()
        }
        guard finished.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL) }
            throw HarnessSetupError("FX inspection timed out. Check FX in Terminal and try again.")
        }
        guard drained.wait(timeout: .now() + 2) == .success else { throw HarnessSetupError("FX inspection output did not close.") }
        guard process.terminationStatus == 0 else { throw HarnessSetupError("FX inspection failed. Check FX in Terminal and try again.") }
        return try capture.result()
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count + bytes.count <= 2_000_000 { data.append(bytes) } else { overflow = true }
    }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !overflow else { throw HarnessSetupError("FX inspection exceeded its response limit.") }
        return data
    }
}
