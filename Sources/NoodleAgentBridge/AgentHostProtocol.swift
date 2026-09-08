import Foundation
import Security

public enum AgentHostIdentity {
    public static var service: String {
        configuredIdentifier(
            key: "NoodleAgentHostService",
            fallback: "com.pdparchitect.noodle.agent-host"
        )
    }

    public static var application: String {
        configuredIdentifier(
            key: "NoodleApplicationIdentifier",
            fallback: "com.pdparchitect.noodle"
        )
    }

    private static func configuredIdentifier(key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return fallback }
        return value
    }

    public static func requirement(for identifier: String, bundle: Bundle = .main) -> String? {
        guard let team = bundle.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

// Deliberately no arbitrary arguments, environment, or shell endpoint. The host
// maps this typed configuration to a fixed command for each trusted harness.
@objc public protocol AgentHostService {
    func start(
        harnessIdentifier: String,
        agentID: String,
        executablePath: String,
        sessionID: String?,
        resumeSession: Bool,
        modelIdentifier: String?,
        effortIdentifier: String?,
        withReply reply: @escaping (Int32, String?) -> Void
    )
    func write(_ data: Data)
    func stop(withReply reply: @escaping (Bool) -> Void)
    func checkCompatibility(withReply reply: @escaping (Bool, String) -> Void)
    func checkAuthentication(
        harnessIdentifier: String,
        executablePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func signIn(
        harnessIdentifier: String,
        executablePath: String,
        withReply reply: @escaping (Bool, String?) -> Void
    )
    func fxModels(executablePath: String, withReply reply: @escaping (Data?, String?) -> Void)
}

@objc public protocol AgentHostClient {
    func receive(_ data: Data, isError: Bool)
    func terminated(_ status: Int32)
    func signInChallenge(_ url: String, code: String)
}
