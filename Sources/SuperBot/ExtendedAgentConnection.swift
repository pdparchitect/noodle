import Foundation
import SuperBotAgentBridge

final class ExtendedAgentConnection: NSObject, AgentHostClient {
    private let connection: NSXPCConnection
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stopping = false

    init(bundle: Bundle = .main) throws {
        guard let requirement = AgentHostIdentity.requirement(for: AgentHostIdentity.service, bundle: bundle) else {
            throw NSError(domain: "SuperBot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Agent Host signing configuration is missing. Rebuild the signed app."])
        }
        connection = NSXPCConnection(serviceName: AgentHostIdentity.service)
        super.init()
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: AgentHostService.self)
        connection.exportedInterface = NSXPCInterface(with: AgentHostClient.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            guard let self, !self.stopping else { return }
            self.onFailure?("Extended runtime disconnected. Turn extended access off and on to reconnect.")
        }
        connection.interruptionHandler = { [weak self] in
            guard let self, !self.stopping else { return }
            self.onFailure?("Extended runtime was interrupted.")
        }
        connection.resume()
    }

    private func proxy(failure: ((String) -> Void)? = nil) -> AgentHostService? {
        connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            (failure ?? self?.onFailure)?(error.localizedDescription)
        } as? AgentHostService
    }

    func start(agentID: UUID, executablePath: String, reply: @escaping (Int32, String?) -> Void) {
        proxy()?.start(agentID: agentID.uuidString, executablePath: executablePath, withReply: reply)
    }
    func write(_ data: Data) { proxy()?.write(data) }
    func stop(reply: @escaping (Bool) -> Void) {
        stopping = true
        proxy(failure: { [weak self] _ in self?.connection.invalidate(); reply(false) })?.stop { [weak self] stopped in
            self?.connection.invalidate()
            reply(stopped)
        }
    }
    func checkCompatibility(reply: @escaping (Bool, String) -> Void) {
        proxy(failure: { reply(false, $0) })?.checkCompatibility(withReply: reply)
    }
    func receive(_ data: Data, isError: Bool) { onData?(data, isError) }
    func terminated(_ status: Int32) { onExit?(status) }
}
