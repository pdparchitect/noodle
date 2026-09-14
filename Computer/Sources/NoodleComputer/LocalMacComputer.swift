import AppKit
import ComputerCore
import Foundation
import LocalMacCore

struct LocalMacSetupRequired: LocalizedError {
    var errorDescription: String? { "Enable Local Mac and approve it in System Settings, then use Start again." }
}

@MainActor enum LocalMacSetup {
    static var desktopApp: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacDesktop.app") }
    static func enable() throws {
        guard Bundle.main.bundleIdentifier == "com.pdparchitect.noodle.computer" else {
            throw ComputerError("Use the installed Noodle Computer app to enable Local Mac. Test builds cannot register the account service.")
        }
        let setup = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacSetup.app")
        guard NSWorkspace.shared.open(setup) else { throw ComputerError("The Local Mac setup app could not be opened.") }
    }
    static func connection() throws -> NSXPCConnection {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NoodleComputerGroup") as? String,
              let team = Bundle.main.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String else { throw ComputerError("Local Mac requires a signed Computer build.") }
        let connection = NSXPCConnection(machServiceName: group + ".localmac", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LocalMacLifecycle.self)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"com.pdparchitect.noodle.computer.localmac\" and certificate leaf[subject.OU] = \"\(team)\"")
        connection.resume()
        return connection
    }
    static func check() async throws {
        let connection = try connection(); defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = Once(continuation)
            let service = connection.remoteObjectProxyWithErrorHandler { _ in
                reply.finish(.failure(LocalMacSetupRequired()))
            } as! LocalMacLifecycle
            service.check { reply.finish(.success(())) }
        }
        guard let team = Bundle.main.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String else { throw ComputerError("Cannot identify the Local Mac service.") }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacSetup.app/Contents/Library/LaunchServices/LocalMacService")
        let requirement = "anchor apple generic and identifier \"com.pdparchitect.noodle.computer.localmac\" and certificate leaf[subject.OU] = \"\(team)\""
        let expected = try LocalMacSignedCode.fingerprint(at: executable, requirement: requirement)
        try await LocalMacServiceUpdate.waitUntilReady(expected: expected) { try await serviceInfo() }
    }
    private static func serviceInfo() async throws -> LocalMacServiceInfo {
        let connection = try connection(); defer { connection.invalidate() }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let reply = Once(continuation, timeout: 5,
                timeoutMessage: "The Local Mac service did not answer its version check. It may still be starting another desktop; retry Start. After an update from the prototype, restart your Mac. Accounts and approvals are retained.")
            let service = connection.remoteObjectProxyWithErrorHandler { _ in
                // check() already established that a service is registered. An
                // older service without this selector needs a normal restart,
                // not registration or another administrator approval.
                reply.finish(.failure(ComputerError(LocalMacServiceInfo.restartMessage)))
            } as! LocalMacLifecycle
            service.serviceInfo { data, error in
                if let error { reply.finish(.failure(ComputerError(error))) }
                else if let data, data.count < 4096 { reply.finish(.success(data)) }
                else { reply.finish(.failure(ComputerError("The Local Mac service returned an invalid version response."))) }
            }
        }
        return try JSONDecoder().decode(LocalMacServiceInfo.self, from: data)
    }
    static func prepare(_ id: UUID) async throws {
        let connection = try connection(); defer { connection.invalidate() }
        let display = try JSONEncoder().encode(LocalMacDisplay())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = Once(continuation)
            let service = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) } as! LocalMacLifecycle
            service.prepare(id, display: display) { data, error in
                if let error { reply.finish(.failure(ComputerError(error))) }
                else if data != nil { reply.finish(.success(())) }
                else { reply.finish(.failure(ComputerError("The helper did not confirm account setup."))) }
            }
        }
    }
    static func stop(_ id: UUID, deleting: Bool = false) async throws {
        let connection = try connection(); defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = Once(continuation)
            let service = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) } as! LocalMacLifecycle
            let finish: (String?) -> Void = { error in
                if let error { reply.finish(.failure(ComputerError(error))) } else { reply.finish(.success(())) }
            }
            if deleting { service.remove(id, reply: finish) } else { service.stop(id, reply: finish) }
        }
    }
}

private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>, timeout: TimeInterval = 120,
         timeoutMessage: String = "Local Mac did not reply. Setup was retained; check its status before retrying.") {
        self.continuation = continuation
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(ComputerError(timeoutMessage)))
        }
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor final class LocalMacComputer: ObservableObject {
    @Published var image: NSImage?
    @Published var status: LocalMacStatus?
    @Published var error: String?
    var latestFrame: Data?
    var onDisconnect: ((String) -> Void)?
    private var input: FileHandle?
    private var output: FileHandle?
    private let writer = DispatchQueue(label: "LocalMac.client.write")
    private var pending: [UUID: CheckedContinuation<LocalMacReply, Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var inputQueue = LocalMacInputQueue()
    private var inputPump: Task<Void, Never>?
    private var closed = true
    private var connectedOnce = false
    private var disconnectExpected = false
    var isConnected: Bool { !closed && input != nil && output != nil }
    private var mainDisplays: Set<CGDirectDisplayID> = []
    private let displayIDs: () -> Set<CGDirectDisplayID>
    init(displayIDs: @escaping () -> Set<CGDirectDisplayID> = LocalMacComputer.currentDisplayIDs) {
        self.displayIDs = displayIDs
    }
    nonisolated static func currentDisplayIDs() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }
    func start(id: UUID) async throws {
        mainDisplays = displayIDs()
        guard !mainDisplays.isEmpty else { throw ComputerError("Cannot verify the main desktop's displays before startup.") }
        try await LocalMacSetup.prepare(id)
        let connection = try LocalMacSetup.connection(); defer { connection.invalidate() }
        let handles: (FileHandle, FileHandle) = try await withCheckedThrowingContinuation { continuation in
            let reply = Once(continuation)
            let service = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) } as! LocalMacLifecycle
            service.connect(id) { data, input, output, error in
                if let error { reply.finish(.failure(ComputerError(error))) }
                else if data != nil, let input, let output { reply.finish(.success((input, output))) }
                else { reply.finish(.failure(ComputerError("The helper did not provide a desktop connection."))) }
            }
        }
        try await connect(input: handles.0, output: handles.1, protectedDisplays: mainDisplays)
    }
    /// The transport can be checked with in-memory pipes, without account setup,
    /// GUI login, service registration, or a privileged test process.
    func connect(input: FileHandle, output: FileHandle, protectedDisplays: Set<UInt32>) async throws {
        guard !connectedOnce else { throw ComputerError("Reconnect with a new desktop connection.") }
        try LocalMacCapturePolicy.validateProtectedDisplays(Array(protectedDisplays))
        connectedOnce = true; mainDisplays = protectedDisplays
        self.input = input; self.output = output; closed = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                while let data = try LocalMacWire.read(input) {
                    let reply = try LocalMacWire.decode(LocalMacReply.self, from: data)
                    DispatchQueue.main.async { [weak self] in self?.receive(reply) }
                }
                DispatchQueue.main.async { [weak self] in self?.disconnect("The background desktop connection closed. Retry Start to reconnect.") }
            } catch { DispatchQueue.main.async { [weak self] in self?.disconnect(error.localizedDescription) } }
        }
        do {
            // Establish protocol compatibility before sending capture or input.
            _ = try await call(.init(.status))
            let current = displayIDs()
            guard !current.isEmpty else { throw ComputerError("Cannot verify the main desktop's displays before capture.") }
            mainDisplays.formUnion(current)
            var stream = LocalMacRequest(.stream); stream.enabled = true
            stream.protectedDisplayIDs = Array(mainDisplays).sorted()
            _ = try await call(stream)
            guard isConnected else { throw ComputerError("The desktop connection closed during startup.") }
        } catch { close(); throw error }
    }
    private func receive(_ reply: LocalMacReply) {
        guard !closed else { return }
        if reply.id == nil, let error = reply.error { disconnect(error); return }
        if let status = reply.status {
            self.status = status
            if !verifyCaptureDisplay() { return }
        }
        if reply.frame, let data = reply.data, status?.displayID != nil {
            guard verifyCaptureDisplay() else { return }
            if let image = NSImage(data: data) { latestFrame = data; self.image = image }
        }
        if let id = reply.id, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = reply.error { continuation.resume(throwing: ComputerError(error)) }
            else { continuation.resume(returning: reply) }
        }
    }
    private func verifyCaptureDisplay() -> Bool {
        guard let id = status?.displayID else { return true }
        let current = displayIDs()
        guard !current.isEmpty, !mainDisplays.contains(id), !current.contains(id) else {
            image = nil; latestFrame = nil
            disconnect("Desktop capture stopped because its display could not be kept separate from the main desktop.")
            return false
        }
        return true
    }
    func call(_ request: LocalMacRequest) async throws -> LocalMacReply {
        try request.validate()
        guard let output, !closed, pending.count < 64 else { throw ComputerError("The desktop connection is unavailable or busy.") }
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            timeouts[request.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.pending.removeValue(forKey: request.id)?.resume(throwing: ComputerError("Desktop request timed out. Its result is uncertain; it was not repeated."))
                self.timeouts.removeValue(forKey: request.id)
            }
            writer.async { [weak self] in
                do { try LocalMacWire.write(data, to: output) }
                catch { DispatchQueue.main.async { [weak self] in self?.disconnect(error.localizedDescription) } }
            }
        }
    }
    func send(_ event: LocalMacInput) {
        guard !closed else { return }
        if !inputQueue.append(event) { error = "Desktop input fell behind and was released. Try again." }
        guard inputPump == nil else { return }
        inputPump = Task {
            defer { inputPump = nil }
            while !Task.isCancelled, let event = inputQueue.next() {
                var request = LocalMacRequest(.input); request.input = event
                do { _ = try await call(request) }
                catch { if !closed { self.error = error.localizedDescription }; inputQueue.removeAll(); break }
            }
        }
    }
    func refreshStatus() async {
        guard isConnected else { return }
        // receive() applies the same display guard to polled and pushed status.
        _ = try? await call(.init(.status))
    }
    func close() { closed = true; disconnect("Desktop disconnected.") }
    func expectDisconnect(_ expected: Bool) { disconnectExpected = expected }
    private func disconnect(_ message: String) {
        let notify = !closed && !disconnectExpected; closed = true
        inputPump?.cancel(); inputPump = nil; inputQueue.removeAll()
        try? output?.close(); output = nil; try? input?.close(); input = nil
        for continuation in pending.values { continuation.resume(throwing: ComputerError(message)) }; pending.removeAll()
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        if notify { error = message; onDisconnect?(message) }
    }
    deinit { try? output?.close(); try? input?.close() }
}
