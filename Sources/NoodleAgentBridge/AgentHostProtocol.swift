import Foundation
import Security

public enum AgentHostIdentity {
    public static let service = "com.pdparchitect.noodle.agent-host"
    public static let application = "com.pdparchitect.noodle"

    public static func requirement(for identifier: String, bundle: Bundle = .main) -> String? {
        guard let team = bundle.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

// Deliberately no arbitrary executable, arguments, environment, or shell endpoint.
@objc public protocol AgentHostService {
    func start(agentID: String, executablePath: String, withReply reply: @escaping (Int32, String?) -> Void)
    func write(_ data: Data)
    func stop(withReply reply: @escaping (Bool) -> Void)
    func checkCompatibility(withReply reply: @escaping (Bool, String) -> Void)
}

@objc public protocol AgentHostClient {
    func receive(_ data: Data, isError: Bool)
    func terminated(_ status: Int32)
}
