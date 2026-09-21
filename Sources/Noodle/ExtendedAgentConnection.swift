import Foundation
import NoodleAgentBridge
import NoodleCore

final class ExtendedAgentConnection: NSObject, AgentHostClient {
    private let connection: NSXPCConnection
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSignInChallenge: ((String, String) -> Void)?
    private var stopping = false

    init(bundle: Bundle = .main) throws {
        guard let requirement = AgentHostIdentity.requirement(for: AgentHostIdentity.service, bundle: bundle) else {
            throw NSError(domain: "Noodle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Agent Host signing configuration is missing. Rebuild the signed app."])
        }
        connection = NSXPCConnection(serviceName: AgentHostIdentity.service)
        super.init()
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: AgentHostService.self)
        connection.exportedInterface = NSXPCInterface(with: AgentHostClient.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            guard let self, !self.stopping else { return }
            self.onFailure?("Agent runtime disconnected. Choose Kick in Settings → Harness to reconnect.")
        }
        connection.interruptionHandler = { [weak self] in
            guard let self, !self.stopping else { return }
            self.onFailure?("Agent runtime was interrupted.")
        }
        connection.resume()
    }

    private func proxy(failure: ((String) -> Void)? = nil) -> AgentHostService? {
        connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            (failure ?? self?.onFailure)?(error.localizedDescription)
        } as? AgentHostService
    }

    func start(
        provider: HarnessProvider,
        agentID: UUID,
        executablePath: String,
        sessionID: UUID? = nil,
        resumeSession: Bool = false,
        modelIdentifier: String? = nil,
        effortIdentifier: String? = nil,
        appsEnabled: Bool = false,
        reply: @escaping (Int32, String?) -> Void
    ) {
        proxy()?.start(
            harnessIdentifier: provider.rawValue,
            agentID: agentID.uuidString,
            executablePath: executablePath,
            sessionID: sessionID?.uuidString,
            resumeSession: resumeSession,
            modelIdentifier: modelIdentifier,
            effortIdentifier: effortIdentifier,
            appsEnabled: appsEnabled,
            withReply: reply
        )
    }
    func startRestrictedCodex(agentID: UUID, executablePath: String, appsEnabled: Bool,
                              reply: @escaping (Int32, String?) -> Void) {
        proxy()?.startRestrictedCodex(agentID: agentID.uuidString, executablePath: executablePath, appsEnabled: appsEnabled, withReply: reply)
    }
    func startRestrictedClaude(agentID: UUID, executablePath: String, sessionID: UUID?, resumeSession: Bool,
                               modelIdentifier: String?, effortIdentifier: String?, appsEnabled: Bool,
                               reply: @escaping (Int32, String?) -> Void) {
        proxy()?.startRestrictedClaude(agentID: agentID.uuidString, executablePath: executablePath,
            sessionID: sessionID?.uuidString, resumeSession: resumeSession, modelIdentifier: modelIdentifier,
            effortIdentifier: effortIdentifier, appsEnabled: appsEnabled, withReply: reply)
    }
    func startRestrictedApple(agentID: UUID, modelIdentifier: String?, reply: @escaping (Int32, String?) -> Void) {
        proxy()?.startRestrictedApple(agentID: agentID.uuidString, modelIdentifier: modelIdentifier, withReply: reply)
    }
    func startRestrictedACP(provider: HarnessProvider, agentID: UUID, executablePath: String,
                            modelIdentifier: String?, effortIdentifier: String?,
                            reply: @escaping (Int32, String?) -> Void) {
        proxy()?.startRestrictedACP(harnessIdentifier: provider.rawValue, agentID: agentID.uuidString,
                                    executablePath: executablePath, modelIdentifier: modelIdentifier,
                                    effortIdentifier: effortIdentifier, withReply: reply)
    }
    func inspectApple(reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.inspectApple(withReply: reply)
    }
    func startRestrictedMuse(agentID: UUID, executablePath: String, modelIdentifier: String?, effortIdentifier: String?,
                             reply: @escaping (Int32, String?) -> Void) {
        proxy()?.startRestrictedMuse(agentID: agentID.uuidString, executablePath: executablePath,
                                     modelIdentifier: modelIdentifier, effortIdentifier: effortIdentifier, withReply: reply)
    }
    func startRestrictedAntigravity(agentID: UUID, executablePath: String, conversationID: UUID?, modelIdentifier: String?,
                                    reply: @escaping (Int32, String?) -> Void) {
        proxy()?.startRestrictedAntigravity(agentID: agentID.uuidString, executablePath: executablePath,
            conversationID: conversationID?.uuidString, modelIdentifier: modelIdentifier, withReply: reply)
    }
    func write(_ data: Data) { proxy()?.write(data) }
    func stop(reply: @escaping (Bool) -> Void) {
        stopping = true
        guard let service = proxy(failure: { _ in reply(false) }) else { reply(false); return }
        service.stop { [self] stopped in
            // Keep the same helper session available after an unconfirmed stop.
            // A new connection cannot confirm ownership of the old process group.
            if stopped { connection.invalidate() }
            reply(stopped)
        }
    }
    func invalidate() {
        stopping = true
        connection.invalidate()
    }
    func checkCompatibility(reply: @escaping (Bool, String) -> Void) {
        proxy(failure: { reply(false, $0) })?.checkCompatibility(withReply: reply)
    }
    func checkAuthentication(
        provider: HarnessProvider,
        executablePath: String,
        reply: @escaping (Bool, String?) -> Void
    ) {
        proxy(failure: { reply(false, $0) })?.checkAuthentication(
            harnessIdentifier: provider.rawValue,
            executablePath: executablePath,
            withReply: reply
        )
    }
    func signIn(
        provider: HarnessProvider,
        executablePath: String,
        reply: @escaping (Bool, String?) -> Void
    ) {
        proxy(failure: { reply(false, $0) })?.signIn(
            harnessIdentifier: provider.rawValue,
            executablePath: executablePath,
            withReply: reply
        )
    }
    func checkProfileAuthentication(profile: UUID, executablePath: String, reply: @escaping (Bool, String?) -> Void) {
        proxy(failure: { reply(false, $0) })?.checkProfileAuthentication(
            profileID: profile.uuidString, executablePath: executablePath, withReply: reply)
    }
    func signInProfile(profile: UUID, executablePath: String, reply: @escaping (Bool, String?) -> Void) {
        proxy(failure: { reply(false, $0) })?.signInProfile(
            profileID: profile.uuidString, executablePath: executablePath, withReply: reply)
    }
    func receive(_ data: Data, isError: Bool) { onData?(data, isError) }
    func terminated(_ status: Int32) { onExit?(status) }
    func signInChallenge(_ url: String, code: String) { onSignInChallenge?(url, code) }
    func fxModels(executablePath: String, reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.fxModels(executablePath: executablePath, withReply: reply)
    }
    func codexModels(executablePath: String, reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.codexModels(executablePath: executablePath, withReply: reply)
    }
    func inspectGrok(reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.inspectGrok(withReply: reply)
    }
    func inspectOpenCode(reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.inspectOpenCode(withReply: reply)
    }
    func inspectMuse(reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.inspectMuse(withReply: reply)
    }
    func inspectAntigravity(reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.inspectAntigravity(withReply: reply)
    }
    func publishHarness(_ staged: StagedHarness, reply: @escaping (String?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.publishHarness(harnessIdentifier: staged.provider.rawValue, version: staged.version,
                                                           stagingID: staged.staging.uuidString, withReply: reply)
    }
    func inspectHarnessVersion(provider: HarnessProvider, executablePath: String, reply: @escaping (Data?, String?) -> Void) {
        proxy(failure: { reply(nil, $0) })?.inspectHarnessVersion(harnessIdentifier: provider.rawValue, executablePath: executablePath, withReply: reply)
    }
}

/// The part of the Agent Host connection a single question needs; tests substitute it.
protocol AgentHostRequestLink: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func invalidate()
}

extension ExtendedAgentConnection: AgentHostRequestLink {}

/// One question to the Agent Host, answered once: by its JSON reply, a lost
/// connection, the timeout or cancellation, whichever comes first.
@MainActor
final class AgentHostRequest<Value: Decodable, Link: AgentHostRequestLink> {
    private let link: Link
    private let sleep: (Duration) async throws -> Void
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeout: Task<Void, Never>?

    init(_ link: Link, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.link = link
        self.sleep = sleep
    }

    /// `disconnected` replaces the connection's own account of why it was lost.
    func load(timeout duration: Duration, noReply: String, timedOut: String, disconnected: String? = nil,
              send: (Link, @escaping (Data?, String?) -> Void) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                link.onFailure = { [weak self] error in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError(disconnected ?? error))) }
                }
                send(link) { [weak self] data, error in
                    Task { @MainActor in
                        do {
                            if let error { throw HarnessSetupError(error) }
                            guard let data else { throw HarnessSetupError(noReply) }
                            self?.finish(.success(try JSONDecoder().decode(Value.self, from: data)))
                        } catch { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self, sleep] in
                    try? await sleep(duration)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(HarnessSetupError(timedOut)))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        link.invalidate()
        continuation.resume(with: result)
    }
}

extension AgentHostRequest where Link == ExtendedAgentConnection {
    convenience init() throws { self.init(try ExtendedAgentConnection()) }
}
