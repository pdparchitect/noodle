import AppKit
import ComputerCore
import Foundation
import LocalMacCore
import ServiceManagement

struct LocalMacSetupRequired: LocalizedError {
    var registration: LocalMacRegistrationStatus = .unknown
    var retryAction = "Start"
    private var setupName: String { LocalMacIdentity(providerID: Bundle.main.bundleIdentifier)?.setupAppName ?? "Noodle Computer Setup" }
    var errorDescription: String? {
        switch registration {
        case .notRegistered: "Enable Local Mac to create and start a separate account on this Mac."
        case .requiresApproval: "Allow \(setupName) in System Settings → General → Login Items & Extensions."
        case .helperMissing: "The Local Mac helper could not be found. Rebuild or reinstall this Computer app."
        case .enabled: "Local Mac’s registered helper did not respond. Choose Repair Local Mac in \(setupName), then retry \(retryAction). Accounts and files are retained."
        case .unknown: "The Local Mac helper did not respond and its approval status could not be checked. Open \(setupName) to check its status."
        }
    }
}

@MainActor enum LocalMacSetup {
    static var desktopApp: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacDesktop.app") }
    static var controlPermissionName: String {
        if #available(macOS 27, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }
    static var desktopName: String { LocalMacIdentity(providerID: Bundle.main.bundleIdentifier)?.desktopAppName ?? "Noodle Local Mac Desktop" }
    static func desktopForPermissions() throws -> URL {
        guard let providerID = Bundle.main.bundleIdentifier,
              let team = Bundle.main.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String else {
            throw ComputerError("Cannot identify the signed desktop helper.")
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Local Mac Permissions", isDirectory: true)
        return try LocalMacPermissionHelper.prepare(source: desktopApp, directory: directory,
                                                    providerID: providerID, team: team)
    }
    static func registrationStatus() async -> LocalMacRegistrationStatus {
        await LocalMacRegistrationProbe.read(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacSetup.app/Contents/MacOS/LocalMacSetup"))
    }
    static func resolve(_ status: LocalMacRegistrationStatus) throws {
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        else { try enable() }
    }
    static func enable() throws {
        guard let identity = LocalMacIdentity(providerID: Bundle.main.bundleIdentifier), identity.permitsAccountService else {
            throw ComputerError("Use the installed Noodle Computer app to enable Local Mac. Test builds cannot register the account service.")
        }
        let setup = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacSetup.app")
        guard NSWorkspace.shared.open(setup) else { throw ComputerError("The Local Mac setup app could not be opened.") }
    }
    static func connection() throws -> NSXPCConnection {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NoodleComputerGroup") as? String,
              let team = Bundle.main.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String else { throw ComputerError("Local Mac requires a signed Computer build.") }
        guard let identity = LocalMacIdentity(providerID: Bundle.main.bundleIdentifier), identity.permitsAccountService,
              group == identity.group(team: team) else { throw ComputerError("The Local Mac service identity does not match this build.") }
        let connection = NSXPCConnection(machServiceName: group + ".localmac", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LocalMacLifecycle.self)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"\(identity.serviceID)\" and certificate leaf[subject.OU] = \"\(team)\"")
        connection.resume()
        return connection
    }
    static func check(retryAction: String = "Start") async throws {
        let registration = await registrationStatus()
        try Task.checkCancellation()
        if registration.needsSetup || registration == .helperMissing {
            throw LocalMacSetupRequired(registration: registration, retryAction: retryAction)
        }
        guard let team = Bundle.main.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String else { throw ComputerError("Cannot identify the Local Mac service.") }
        guard let identity = LocalMacIdentity(providerID: Bundle.main.bundleIdentifier) else { throw ComputerError("Cannot identify the Local Mac service.") }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacSetup.app/Contents/Library/LaunchServices/LocalMacService")
        let requirement = "anchor apple generic and identifier \"\(identity.serviceID)\" and certificate leaf[subject.OU] = \"\(team)\""
        let expected = try LocalMacSignedCode.fingerprint(at: executable, requirement: requirement)
        // Do not gate this on check(): an old image's reply can fail macOS code
        // validation after replacement, preventing it from reaching serviceInfo
        // and its normal restart path. No lifecycle mutation is sent here.
        do { try await LocalMacServiceUpdate.waitUntilReady(expected: expected) { try await serviceInfo() } }
        catch is LocalMacServiceUnavailable {
            throw LocalMacSetupRequired(registration: registration, retryAction: retryAction)
        }
    }
    private static func serviceInfo() async throws -> LocalMacServiceInfo {
        let connection = try connection(); defer { connection.invalidate() }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let reply = Once(continuation, timeout: 3, timeoutError: LocalMacServiceUnavailable())
            let service = connection.remoteObjectProxyWithErrorHandler { _ in
                reply.finish(.failure(LocalMacServiceUnavailable()))
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
        // Resolve helper replacement before sending the new deletion selector.
        // Only the read-only handshake may retry; deletion itself is sent once.
        if deleting { try await check(retryAction: "Delete") }
        let connection = try connection(); defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = Once(continuation)
            let service = connection.remoteObjectProxyWithErrorHandler { reply.finish(.failure($0)) } as! LocalMacLifecycle
            let finish: (String?) -> Void = { error in
                if let error { reply.finish(.failure(ComputerError(error))) } else { reply.finish(.success(())) }
            }
            if deleting {
                service.removeAccount(id) { data, error in
                    if let data {
                        guard data.count < 65_536,
                              let failure = try? JSONDecoder().decode(LocalMacRemovalFailure.self, from: data) else {
                            reply.finish(.failure(ComputerError(error ?? "The helper returned an invalid deletion response. Check this computer before retrying.")))
                            return
                        }
                        reply.finish(.failure(failure))
                    } else { finish(error) }
                }
            } else { service.stop(id, reply: finish) }
        }
    }
}

private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>, timeout: TimeInterval = 120,
         timeoutMessage: String = "Local Mac did not reply. Setup was retained; check its status before retrying.",
         timeoutError: Error? = nil) {
        self.continuation = continuation
        // XPC may discard both callbacks on an invalidated connection. Keep
        // the continuation alive until its deadline even in that case.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(timeoutError ?? ComputerError(timeoutMessage)))
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
    @Published var windowPreview: LocalMacWindowPreview?
    var latestFrame: Data?
    var onDisconnect: ((String) -> Void)?
    private var input: FileHandle?
    private var output: FileHandle?
    private let writer = DispatchQueue(label: "LocalMac.client.write")
    private var pending: [UUID: CheckedContinuation<LocalMacReply, Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var inputQueue = LocalMacInputQueue()
    private var inputPump: Task<Void, Never>?
    private var inputFailure: String?
    private var closed = true
    private var connectedOnce = false
    private var streamRequested = false
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
            try await startCaptureIfPermitted()
            guard isConnected else { throw ComputerError("The desktop connection closed during startup.") }
        } catch { close(); throw error }
    }
    private func startCaptureIfPermitted() async throws {
        // Keep the connection (and Stop/Delete) usable while consent is missing.
        // Entering ScreenCaptureKit here can wait on an unseen background prompt.
        guard !streamRequested, let status, status.screenCapture, status.canControl else { return }
        let current = displayIDs()
        guard !current.isEmpty else { throw ComputerError("Cannot verify the main desktop's displays before capture.") }
        mainDisplays.formUnion(current)
        var stream = LocalMacRequest(.stream); stream.enabled = true
        stream.protectedDisplayIDs = Array(mainDisplays).sorted()
        streamRequested = true
        _ = try await call(stream)
    }
    private func receive(_ reply: LocalMacReply) {
        guard !closed else { return }
        if let id = reply.previewID {
            if windowPreview?.id == id {
                // The source stream ended, so its focus panel must go with it.
                // Clearing the preview also rejects queued input and late frames.
                closeWindowPreview()
            }
            return
        }
        if reply.id == nil, let error = reply.error { disconnect(error); return }
        if let status = reply.status {
            self.status = status
            if !verifyCaptureDisplay() { return }
            if status.canControl, inputFailure == LocalMacStatus.inputPermissionError { clearInputFailure() }
        }
        if reply.frame, let data = reply.data, status?.displayID != nil {
            guard verifyCaptureDisplay() else { return }
            if let geometry = reply.windowFrame {
                if windowPreview?.id == geometry.previewID, let image = NSImage(data: data) {
                    windowPreview?.image = image; windowPreview?.geometry = geometry
                }
            } else if let image = NSImage(data: data) { latestFrame = data; self.image = image }
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
                let message = request.operation == .stream
                    ? "The desktop did not finish starting. Stop this computer and try Start again, or delete it."
                    : "Desktop request timed out. Its result is uncertain; it was not repeated."
                self.pending.removeValue(forKey: request.id)?.resume(throwing: ComputerError(message))
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
        if !inputQueue.append(event) { recordInputFailure("Desktop input fell behind and was released. Try again.") }
        guard inputPump == nil else { return }
        inputPump = Task {
            defer { inputPump = nil }
            while !Task.isCancelled, let event = inputQueue.next() {
                if let id = event.previewID, windowPreview?.id != id { continue }
                var request = LocalMacRequest(.input); request.input = event
                do { _ = try await call(request); clearInputFailure() }
                catch {
                    if !closed, event.previewID == nil || windowPreview?.id == event.previewID {
                        recordInputFailure(error.localizedDescription)
                        if event.previewID != nil { windowPreview?.error = error.localizedDescription }
                    }
                    inputQueue.removeAll(); break
                }
            }
        }
    }
    private func recordInputFailure(_ message: String) { inputFailure = message; error = message }
    private func clearInputFailure() {
        // A successful input or restored grant must not dismiss an unrelated
        // transport/capture failure that arrived in the meantime.
        if let inputFailure, error == inputFailure { error = nil }
        if let inputFailure, windowPreview?.error == inputFailure { windowPreview?.error = nil }
        inputFailure = nil
    }
    func refreshStatus() async {
        guard isConnected else { return }
        // receive() applies the same display guard to polled and pushed status.
        _ = try? await call(.init(.status))
        guard isConnected else { return }
        do { try await startCaptureIfPermitted() }
        catch { self.error = error.localizedDescription }
    }
    func openWindowPreview() async {
        guard windowPreview == nil, isConnected, !disconnectExpected, status?.canControl == true,
              let window = status?.focusedWindow else { return }
        let preview = LocalMacWindowPreview(window: window)
        windowPreview = preview
        var request = LocalMacRequest(.windowPreview)
        request.previewID = preview.id; request.window = window; request.enabled = true
        do { _ = try await call(request) }
        catch { if windowPreview?.id == preview.id { windowPreview?.error = error.localizedDescription } }
    }
    func closeWindowPreview() {
        guard let id = windowPreview?.id else { return }
        windowPreview = nil
        send(LocalMacInput(.reset))
        guard isConnected else { return }
        Task {
            var request = LocalMacRequest(.windowPreview); request.previewID = id; request.enabled = false
            do { _ = try await call(request) }
            catch { if isConnected { self.error = error.localizedDescription } }
        }
    }
    func close() { closed = true; disconnect("Desktop disconnected.") }
    func expectDisconnect(_ expected: Bool) { disconnectExpected = expected }
    private func disconnect(_ message: String) {
        let notify = !closed && !disconnectExpected; closed = true
        windowPreview = nil
        inputPump?.cancel(); inputPump = nil; inputQueue.removeAll()
        try? output?.close(); output = nil; try? input?.close(); input = nil
        for continuation in pending.values { continuation.resume(throwing: ComputerError(message)) }; pending.removeAll()
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        if notify { error = message; onDisconnect?(message) }
    }
    deinit { try? output?.close(); try? input?.close() }
}
