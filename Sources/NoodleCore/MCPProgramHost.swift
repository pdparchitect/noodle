import Foundation

/// The unsandboxed helper that starts a program. Only this app may connect.
public enum MCPProgramHostIdentity {
    public static var service: String {
        configured("NoodleMCPProgramHostService", fallback: "com.pdparchitect.noodle.mcp-program-host")
    }

    public static var application: String {
        configured("NoodleApplicationIdentifier", fallback: "com.pdparchitect.noodle")
    }

    private static func configured(_ key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return fallback }
        return value
    }

    public static func requirement(for identifier: String, bundle: Bundle = .main) -> String? {
        guard let team = bundle.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// Starts one consented program and returns its pipes. The caller does not choose a shell.
@objc public protocol MCPProgramHostService {
    func launch(executable: String, arguments: [String], environment: [String: String], directory: String,
                withReply reply: @escaping (Int32, FileHandle?, FileHandle?, FileHandle?, String?) -> Void)
    func stop(_ processIdentifier: Int32)
}

/// The helper applies this before exec. It is not the app sandbox.
/// A helper that is already inside the app sandbox cannot apply another profile.
public enum MCPProgramHostLaunch {
    public static let profile = "(version 1)\n(allow default)\n"

    public static func command(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        ("/usr/bin/sandbox-exec", ["-p", profile, executable] + arguments)
    }

    public static func refusesAppSandbox(containerIdentifier: String?) -> Bool {
        guard let containerIdentifier else { return false }
        return !containerIdentifier.isEmpty
    }
}
