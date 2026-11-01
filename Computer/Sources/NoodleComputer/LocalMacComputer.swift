import AppKit
import ComputerCore
import Foundation
import LocalMacCore
import ServiceManagement
import Surface

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
        let reported = await LocalMacRegistrationProbe.read(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalMacSetup.app/Contents/MacOS/LocalMacSetup"))
        return await confirmed(reported) { (try? await serviceInfo()) != nil }
    }
    /// macOS 27 can report a registered, running daemon as not found when
    /// backgroundtaskmanagementd fails to resolve its owning app, and registering
    /// it again then fails with EPERM. launchd only serves the signed service's
    /// Mach name while the daemon is registered, so an answer settles it.
    static func confirmed(_ reported: LocalMacRegistrationStatus,
                          serviceAnswers: () async -> Bool) async -> LocalMacRegistrationStatus {
        guard reported == .notRegistered else { return reported }
        return await serviceAnswers() ? .enabled : reported
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
    @Published var windowPreviews: [UUID: LocalMacWindowPreview] = [:]
    @Published private(set) var openingAllWindows = false
    lazy var windowPresenter = LocalMacWindowPreviewPresenter(runtime: self)
    var onDisconnect: ((String) -> Void)?
    private var input: FileHandle?
    private var output: FileHandle?
    private let writer = DispatchQueue(label: "LocalMac.client.write")
    private let frames = LocalMacFrameReader()
    private var pending: [UUID: (Result<LocalMacReply, Error>) -> Void] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var inputQueue = LocalMacInputQueue()
    /// Input goes out without waiting for each reply; the helper handles it in order.
    private static let inputsInFlightLimit = 8
    private var inputsInFlight = 0
    private var inputFailure: String?
    private var closed = true
    private var connectedOnce = false
    private var streamRequested = false
    /// Capture pauses while the main desktop's displays are unknown, as when the
    /// Mac is locked. Terminals and files keep running; capture resumes once the
    /// displays return, after the helper has confirmed the stop.
    private var captureStop: Task<Void, Never>?
    private var captureResume: Task<Void, Never>?
    private var disconnectExpected = false
    var isConnected: Bool { !closed && input != nil && output != nil }
    private var mainDisplays: Set<CGDirectDisplayID> = []
    private let displayIDs: () -> Set<CGDirectDisplayID>
    private let presentsWindows: Bool
    init(displayIDs: @escaping () -> Set<CGDirectDisplayID> = LocalMacComputer.currentDisplayIDs, presentsWindows: Bool = true) {
        self.displayIDs = displayIDs; self.presentsWindows = presentsWindows
    }
    nonisolated static func currentDisplayIDs() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }
    func start(id: UUID) async throws {
        // Empty while the Mac is locked. Only capture needs these displays, so
        // the computer starts without it and captures once they are known.
        mainDisplays = displayIDs()
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
        // An empty set means the displays are unknown, not that none need
        // protecting: the helper refuses to capture without them.
        if !protectedDisplays.isEmpty { try LocalMacCapturePolicy.validateProtectedDisplays(Array(protectedDisplays)) }
        connectedOnce = true; mainDisplays = protectedDisplays
        self.input = input; self.output = output; closed = false
        let frames = frames, writer = writer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reader = LocalMacWire.Reader(input)
            do {
                // This block never returns while the desktop is connected, so each message drains
                // its own autorelease pool; otherwise every frame's pixels stayed in memory.
                while try autoreleasepool(invoking: {
                    guard let data = try reader.read() else { return false }
                    let reply = try LocalMacWire.decode(LocalMacReply.self, from: data)
                    if let region = reply.region {
                        guard let descriptor = reader.takeDescriptor() else {
                            throw ComputerError("The desktop helper sent pictures without their memory.")
                        }
                        try frames.add(region, descriptor: descriptor)
                    }
                    // Copied here, off the main thread, so the slot goes back to the helper at once.
                    var image: NSImage?
                    if let frame = reply.sharedFrame, let picture = frames.image(frame) {
                        image = NSImage(cgImage: picture, size: CGSize(width: picture.width, height: picture.height))
                        var release = LocalMacRequest(.frameRelease); release.frame = frame
                        if let request = try? JSONEncoder().encode(release) {
                            writer.async { try? LocalMacWire.write(request, to: output) }
                        }
                    }
                    DispatchQueue.main.async { [weak self] in self?.receive(reply, image: image) }
                    return true
                }) {}
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
        // The helper handles requests concurrently: never start while a stop is
        // still in flight, or the stop could end the new stream.
        guard !streamRequested, captureStop == nil, let status, status.screenCapture, status.canControl else { return }
        let current = displayIDs()
        guard !current.isEmpty else { resumeCaptureWhenDisplaysReturn(); return }
        captureResume?.cancel(); captureResume = nil
        mainDisplays.formUnion(current)
        var stream = LocalMacRequest(.stream); stream.enabled = true
        stream.protectedDisplayIDs = Array(mainDisplays).sorted()
        streamRequested = true
        _ = try await call(stream)
    }
    private func pauseCapture() {
        image = nil
        if !windowPreviews.isEmpty {
            for id in windowPreviews.keys { frames.remove(stream: id) }
            windowPreviews.removeAll(); windowPresenter.dismissAll()
        }
        streamRequested = false
        // Already stopped and waiting for the displays: status updates while
        // locked need no further stop.
        guard captureStop == nil, captureResume == nil else { return }
        // Stopping the stream also ends the helper's window captures.
        captureStop = Task { [weak self] in
            var stop = LocalMacRequest(.stream); stop.enabled = false
            _ = try? await self?.call(stop)
            guard let self, !Task.isCancelled else { return }
            self.captureStop = nil
            self.resumeCaptureWhenDisplaysReturn()
        }
    }
    /// The desktop view polls too, but only while it is shown; bots and
    /// terminal-only use also need capture back after the Mac is unlocked.
    private func resumeCaptureWhenDisplaysReturn() {
        guard captureResume == nil else { return }
        captureResume = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { return }
                if !self.displayIDs().isEmpty {
                    self.captureResume = nil
                    await self.refreshStatus()
                    return
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    private func receive(_ reply: LocalMacReply, image frame: NSImage?) {
        guard !closed else { return }
        // A region can arrive for a preview closed while it was on the way.
        if let stream = reply.region?.stream, windowPreviews[stream] == nil { frames.remove(stream: stream) }
        if let id = reply.previewID {
            // Only the ended root is removed; sibling previews and the desktop
            // keep running. Unknown IDs are late messages from closed streams.
            if windowPreviews[id] != nil { closeWindowPreview(id) }
            return
        }
        if reply.id == nil, let error = reply.error { disconnect(error); return }
        if let status = reply.status {
            self.status = status
            // A paused capture still answers the request below; only a
            // disconnect has already failed every pending request.
            if verifyCaptureDisplay(), status.canControl, inputFailure == LocalMacStatus.inputPermissionError { clearInputFailure() }
            guard !closed else { return }
        }
        if reply.frame, let frame, status?.displayID != nil, verifyCaptureDisplay() {
            if let geometry = reply.windowFrame {
                if windowPreviews[geometry.previewID] != nil {
                    windowPreviews[geometry.previewID]?.image = frame
                    windowPreviews[geometry.previewID]?.geometry = geometry
                    windowPresenter.sync(geometry.previewID)
                }
            } else { image = frame }
        }
        if let id = reply.id, let finish = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            finish(reply.error.map { .failure(ComputerError($0)) } ?? .success(reply))
        }
    }
    /// Frames are shown only while the main desktop's displays are known and
    /// none of them is the one captured. Unknown displays (a locked Mac) pause
    /// capture; a captured main-desktop display ends the connection.
    private func verifyCaptureDisplay() -> Bool {
        guard let id = status?.displayID else { return true }
        let current = displayIDs()
        if mainDisplays.contains(id) || current.contains(id) {
            image = nil
            disconnect("Desktop capture stopped because its display could not be kept separate from the main desktop.")
            return false
        }
        guard !current.isEmpty else { pauseCapture(); return false }
        return true
    }
    func call(_ request: LocalMacRequest) async throws -> LocalMacReply {
        try await withCheckedThrowingContinuation { continuation in
            do { try submit(request) { continuation.resume(with: $0) } }
            catch { continuation.resume(throwing: error) }
        }
    }
    /// Writes the request at once, in the order submitted; `finish` runs on the main actor.
    private func submit(_ request: LocalMacRequest, finish: @escaping (Result<LocalMacReply, Error>) -> Void) throws {
        try request.validate()
        guard let output, !closed, pending.count < 64 else { throw ComputerError("The desktop connection is unavailable or busy.") }
        let data = try JSONEncoder().encode(request)
        pending[request.id] = finish
        timeouts[request.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            let message = request.operation == .stream
                ? "The desktop did not finish starting. Stop this computer and try Start again, or delete it."
                : "Desktop request timed out. Its result is uncertain; it was not repeated."
            self.pending.removeValue(forKey: request.id)?(.failure(ComputerError(message)))
            self.timeouts.removeValue(forKey: request.id)
        }
        writer.async { [weak self] in
            do { try LocalMacWire.write(data, to: output) }
            catch { DispatchQueue.main.async { [weak self] in self?.disconnect(error.localizedDescription) } }
        }
    }
    func send(_ event: LocalMacInput) {
        guard !closed else { return }
        if !inputQueue.append(event) { recordInputFailure("Desktop input fell behind and was released. Try again.") }
        sendQueuedInput()
    }
    private func sendQueuedInput() {
        while !closed, inputsInFlight < Self.inputsInFlightLimit, let event = inputQueue.next() {
            if let id = event.previewID, windowPreviews[id] == nil, event.kind != .reset { continue }
            var request = LocalMacRequest(.input); request.input = event
            inputsInFlight += 1
            do { try submit(request) { [weak self] in self?.inputFinished(event, $0) } }
            catch { inputFinished(event, .failure(error)) }
        }
    }
    private func inputFinished(_ event: LocalMacInput, _ result: Result<LocalMacReply, Error>) {
        inputsInFlight -= 1
        switch result {
        case .success:
            if let id = event.previewID { windowPreviews[id]?.error = nil }
            else { clearInputFailure() }
        case .failure(let error):
            if !closed {
                if let id = event.previewID { windowPreviews[id]?.error = error.localizedDescription }
                else { recordInputFailure(error.localizedDescription) }
            }
            // Input already sent cannot be recalled; drop what has not gone out yet.
            if let id = event.previewID { inputQueue.remove(previewID: id) } else { inputQueue.removeAll() }
        }
        sendQueuedInput()
    }
    private func recordInputFailure(_ message: String) { inputFailure = message; error = message }
    private func clearInputFailure() {
        // A successful input or restored grant must not dismiss an unrelated
        // transport/capture failure that arrived in the meantime.
        if let inputFailure, error == inputFailure { error = nil }
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
    /// A capture that failed in the helper stays requested, so polling never
    /// asks again; the person can.
    var canRetryCapture: Bool { isConnected && captureStop == nil && status?.detail != nil && status?.displayID == nil }
    func retryCapture() async {
        guard canRetryCapture else { return }
        streamRequested = false
        do { try await startCaptureIfPermitted() }
        catch { self.error = error.localizedDescription }
    }
    func openWindowPreview(window selected: LocalMacWindow? = nil, bringToFront: Bool = true) async {
        guard isConnected, !disconnectExpected, status?.canControl == true,
              let window = selected ?? status?.focusedWindow else { return }
        if let existing = windowPreviews.values.first(where: { $0.window.hasSameIdentity(as: window) }) {
            if presentsWindows { windowPresenter.show(existing.id, bringToFront: bringToFront) }
            return
        }
        guard windowPreviews.count < LocalMacWindowCaptureLimits.maximumWindows else {
            error = "Close an unused window before opening another (32 windows maximum)."; return
        }
        let preview = LocalMacWindowPreview(window: window)
        windowPreviews[preview.id] = preview
        if presentsWindows { windowPresenter.show(preview.id, bringToFront: bringToFront) }
        var request = LocalMacRequest(.windowPreview)
        request.previewID = preview.id; request.window = window; request.enabled = true
        do { _ = try await call(request) }
        catch { windowPreviews[preview.id]?.error = error.localizedDescription }
    }
    func openAllWindowPreviews() async {
        guard !openingAllWindows, isConnected, !disconnectExpected, status?.canControl == true else { return }
        openingAllWindows = true
        defer { openingAllWindows = false }
        do {
            let reply = try await call(.init(.windowList))
            guard let windows = reply.windows else { throw ComputerError("The desktop did not return its visible windows.") }
            if windows.isEmpty { error = "No visible application windows."; return }
            // Back to front preserves the account's stacking order. Repeated
            // clicks reuse existing windows rather than creating duplicate streams.
            for window in windows.reversed() {
                guard isConnected, !disconnectExpected else { return }
                await openWindowPreview(window: window, bringToFront: false)
            }
            if presentsWindows { windowPresenter.arrange(restoreMinimized: true) }
            if let first = windows.first,
               let preview = windowPreviews.values.first(where: { $0.window.hasSameIdentity(as: first) }) {
                if presentsWindows { windowPresenter.show(preview.id) }
            }
        } catch { if isConnected { self.error = error.localizedDescription } }
    }
    func closeWindowPreview(_ id: UUID) {
        guard windowPreviews.removeValue(forKey: id) != nil else { return }
        frames.remove(stream: id)
        windowPresenter.dismiss(id)
        var reset = LocalMacInput(.reset); reset.previewID = id
        send(reset)
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
        windowPreviews.removeAll(); windowPresenter.dismissAll(); frames.removeAll()
        inputQueue.removeAll()
        captureStop?.cancel(); captureStop = nil; captureResume?.cancel(); captureResume = nil
        // Wakes the reader, which reads through a descriptor of its own.
        if let output { Darwin.shutdown(output.fileDescriptor, SHUT_RDWR) }
        try? output?.close(); output = nil; try? input?.close(); input = nil
        let failed = pending.values; pending.removeAll()
        for finish in failed { finish(.failure(ComputerError(message))) }
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        if notify { error = message; onDisconnect?(message) }
    }
    deinit { try? output?.close(); try? input?.close() }
}

/// A Local Mac's desktop as a live view through the Hub: the frames the app already shows, and
/// what the viewer does as the helper's input, at positions relative to the picture.
enum LocalMacLiveView {
    static func picture(_ image: NSImage) -> (image: CGImage, size: CGSize)? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, image.size) }
    }

    static func events(for input: SurfaceInput, size: CGSize) -> [LocalMacInput] {
        guard size.width > 0, size.height > 0 else { return [] }
        func at(_ kind: LocalMacInput.Kind, _ x: Double, _ y: Double) -> LocalMacInput {
            var event = LocalMacInput(kind)
            event.x = min(1, max(0, x / size.width)); event.y = min(1, max(0, y / size.height))
            return event
        }
        func key(_ code: UInt16, down: Bool) -> LocalMacInput {
            var event = LocalMacInput(down ? .keyDown : .keyUp); event.key = code
            return event
        }
        switch input {
        case .pointer(let phase, let x, let y, let clickCount):
            // The helper turns a move with the button held into a drag.
            let kinds: [SurfaceInput.Phase: LocalMacInput.Kind] = [.move: .move, .drag: .move, .down: .down, .up: .up]
            var event = at(kinds[phase] ?? .move, x, y)
            event.clickCount = min(10, max(1, clickCount))
            return [event]
        case .scroll(let x, let y, _, let dy):
            var event = at(.scroll, x, y)
            event.scroll = min(10_000, max(-10_000, -dy))
            return [event]
        case .key(let named):
            guard let code = keyCodes[named.rawValue] else { return [] }
            return [key(code, down: true), key(code, down: false)]
        case .hold(let named, let pressed):
            guard let code = keyCodes[named] else { return [] }
            return [key(code, down: pressed)]
        case .text(let text):
            var event = LocalMacInput(.text); event.text = String(text.utf16.prefix(4096)) ?? ""
            return [event]
        }
    }

    private static let keyCodes: [String: UInt16] = [
        "enter": 36, "tab": 48, "escape": 53, "backspace": 51, "space": 49,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
