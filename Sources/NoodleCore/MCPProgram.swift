import Foundation

/// A program Noodle starts and talks to over standard input and output.
/// The registry stores the command, never the secret environment values.
public struct MCPProgramRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var description: String
    public var instructions: String
    public fileprivate(set) var skillName: String
    mutating func allocateSkillName(_ name: String) { skillName = name }
    /// Names only. The values live in the login keychain.
    public var environmentNames: [String]
    /// What the person allowed. Nil leaves the program unconnected.
    public var consentedSubject: String?

    public init(id: UUID = UUID(), name: String, executable: String, arguments: [String] = [],
                description: String = "", instructions: String = "", environmentNames: [String] = [],
                consentedSubject: String? = nil) throws {
        self.id = id
        self.name = try ConversationName.validated(name)
        self.executable = try Self.validatedExecutable(executable)
        self.arguments = try arguments.map(Self.validatedArgument)
        self.description = String(description.prefix(1_000))
        self.instructions = String(instructions.prefix(20_000))
        self.skillName = Self.skillName(for: name)
        self.environmentNames = try Self.validatedNames(environmentNames)
        self.consentedSubject = consentedSubject
    }

    public static func validatedExecutable(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1_024, !trimmed.contains("\n"), !trimmed.contains("\0"),
              !trimmed.contains(" ") else {
            throw MCPConnectionError.message("Enter the executable in its own field, without spaces or a shell command.")
        }
        return trimmed
    }

    public static func validatedArgument(_ text: String) throws -> String {
        guard !text.isEmpty, text.count <= 4_096, !text.contains("\n"), !text.contains("\0") else {
            throw MCPConnectionError.message("Enter each argument in its own field.")
        }
        return text
    }

    public static func validatedNames(_ names: [String]) throws -> [String] {
        guard names.count <= 32 else {
            throw MCPConnectionError.message("A program can have at most 32 environment values.")
        }
        var seen: Set<String> = []
        return try names.map { name in
            guard name.count <= 128, name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789").contains($0) }),
                  let first = name.unicodeScalars.first, CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ_").contains(first),
                  seen.insert(name).inserted else {
                throw MCPConnectionError.message("Enter each environment name as a single word, such as OPENAPI_MCP_HEADERS.")
            }
            return name
        }
    }

    /// The absolute executable, every argument, the working directory and the environment names.
    public static func subject(executable: URL, arguments: [String], workingDirectory: URL, environmentNames: [String]) -> String {
        ([executable.path] + arguments + [workingDirectory.path] + environmentNames.sorted()).joined(separator: "\n")
    }

    public static func mayDownloadCode(executable: String, arguments: [String]) -> Bool {
        let base = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        if ["npx", "npm", "pnpm", "yarn", "bunx", "bun", "deno"].contains(base) { return true }
        return arguments.contains("-y") || arguments.contains("--yes")
    }

    public static func consentText(executable: URL, arguments: [String], workingDirectory: URL,
                                   user: String, mayDownload: Bool) -> String {
        var lines = [
            "Noodle on this Mac will run \(executable.path) as \(user), outside any agent's sandbox.",
            "Working directory: \(workingDirectory.path)",
            arguments.isEmpty ? "Arguments: none" : "Arguments: \(arguments.joined(separator: " "))",
            "It runs with that account's files. Tool output it returns reaches the agents you assign."
        ]
        if mayDownload {
            lines.append("This command can download and run code. Prefer a pinned version.")
        }
        return lines.joined(separator: "\n")
    }

    /// A bare name is looked up. A path must already be absolute. Nothing is downloaded here.
    public static func resolveExecutable(_ text: String, lookup: (String) -> URL?) throws -> URL {
        let executable = try validatedExecutable(text)
        if executable.contains("/") {
            guard executable.hasPrefix("/") else {
                throw MCPConnectionError.message("Enter an absolute path or a program name.")
            }
            return URL(fileURLWithPath: executable)
        }
        guard let found = lookup(executable), found.isFileURL, found.path.hasPrefix("/") else {
            throw MCPConnectionError.message("Noodle could not find \(executable).")
        }
        return found
    }

    /// Looks up a bare name in PATH. It does not run the program.
    public static func pathLookup(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? minimalEnvironment(user: NSUserName(), temporaryDirectory: NSTemporaryDirectory())["PATH"]
            ?? ""
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static func workingDirectory(root: URL, id: UUID) -> URL {
        root.appendingPathComponent("MCP/programs/\(id.uuidString.lowercased())", isDirectory: true)
    }

    /// Declared names plus the small environment Noodle always supplies. The parent environment is not copied.
    public static func environment(values: [String: String], names: [String], minimal: [String: String]) -> [String: String] {
        var result = minimal
        for name in names {
            result[name] = values[name] ?? ""
        }
        return result
    }

    public static func minimalEnvironment(user: String, temporaryDirectory: String) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "TMPDIR": temporaryDirectory,
            "LANG": "C",
            "USER": user,
            "LOGNAME": user
        ]
    }

    public static func redact(_ text: String, secrets: [String]) -> String {
        secrets.filter { $0.count >= 4 }.reduce(text) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[redacted]")
        }
    }

    /// One standard-output line is one MCP message. Any other line closes the connection.
    public static func mcpMessageLine(_ line: String) throws -> Data {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any] else {
            throw MCPConnectionError.message("The program wrote something other than an MCP message. The connection was closed.")
        }
        return data
    }

    public static let maximumRestarts = 3
    public static let idleSeconds: TimeInterval = 15 * 60
    public static let startTimeoutSeconds: TimeInterval = 20

    public static func restartDelay(after failure: Int) -> TimeInterval {
        let bounded = min(max(failure, 0), 5)
        return 0.25 * pow(2, Double(bounded))
    }

    /// After this process's parent is gone, a launched program must be stopped.
    public static func parentHasExited(_ parentProcessID: Int32) -> Bool { parentProcessID <= 1 }

    /// Shown on a restricted agent's assignment. The program is not inside that sandbox.
    public static func assignmentWarning(restricted: Bool) -> String? {
        guard restricted else { return nil }
        return "This program runs outside this agent's sandbox and can reach more than that sandbox does."
    }

    /// Start on first use, stop after idle, and stop retrying after a bounded run of crashes.
    public struct Lifecycle: Equatable, Sendable {
        public var failures = 0
        public var failed = false
        public var running = false
        public var lastUse = Date()
        public init() {}
        public mutating func started(at date: Date) {
            running = true
            lastUse = date
        }
        public mutating func used(at date: Date) { lastUse = date }
        public mutating func stopped() { running = false }
        /// Nil means the program stays stopped in the failed state.
        public mutating func crashed() -> TimeInterval? {
            running = false
            failures += 1
            guard failures <= MCPProgramRecord.maximumRestarts else {
                failed = true
                return nil
            }
            return MCPProgramRecord.restartDelay(after: failures - 1)
        }
        public func isIdle(at now: Date, limit: TimeInterval = MCPProgramRecord.idleSeconds) -> Bool {
            running && now.timeIntervalSince(lastUse) >= limit
        }
    }

    private static func skillName(for name: String) -> String {
        let slug = name.lowercased().unicodeScalars.map {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0) ? String($0) : "-"
        }.joined().split(separator: "-").joined(separator: "-")
        let prefix = String(slug.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "mcp-" + (prefix.isEmpty ? "program" : prefix)
    }
}
