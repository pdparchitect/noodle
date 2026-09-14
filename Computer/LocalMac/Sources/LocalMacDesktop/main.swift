import AppKit
import ApplicationServices
import LocalMacCore
import LocalMacPrivate
import Darwin

/// The desktop protocol runs as the managed standard user over inherited pipes.
/// There is no listening socket, privileged command execution, or host clipboard.
@MainActor final class Desktop {
    let session: LocalMacSession
    let output: Output
    let capture: AccountCapture
    var terminals: [UUID: Terminal] = [:]
    let files: LocalMacFileWorker
    private var shuttingDown = false
    var guardTimer: Timer?
    var controls: AccountInput?
    init(session: LocalMacSession, output: Output) {
        self.session = session; self.output = output
        files = LocalMacFileWorker(home: session.account.home) { try session.verifyCurrent() }
        capture = AccountCapture(session: session, output: output)
        capture.onChange = { [weak self] in self?.sendStatus() }
    }
    func sendStatus() {
        var ready = LocalMacReply(); ready.status = status(); output.send(ready)
    }
    func status() -> LocalMacStatus {
        let apps = NSWorkspace.shared.runningApplications.filter { NLMPIDBelongsToUser($0.processIdentifier, session.account.uid) }
        var value = LocalMacStatus(screenCapture: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted(),
            postEvents: CGPreflightPostEventAccess(), display: session.account.display,
            setupRunning: apps.contains { $0.bundleIdentifier == "com.apple.SetupAssistant" }, detail: capture.error)
        value.displayID = capture.displayID
        return value
    }
    func begin() {
        guardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.session.verifyCurrent() }
                catch { self.shutdown() }
            }
        }
        sendStatus()
    }
    func handle(_ request: LocalMacRequest) async {
        guard !shuttingDown else { return }
        var response = LocalMacReply(id: request.id)
        do {
            try session.verifyCurrent(); try request.validate()
            switch request.operation {
            case .status: response.status = status()
            case .screenshot:
                response.data = try capture.screenshot()
            case .stream:
                if request.enabled == true {
                    await capture.start(protectedDisplayIDs: request.protectedDisplayIDs ?? [])
                } else { await capture.stop() }
                response.status = status()
            case .input: try post(request.input!)
            case .terminalOpen:
                guard terminals.count < 16 else { throw LocalMacError("Close an unused terminal before opening another.") }
                let terminal = try Terminal(home: session.account.home); terminals[terminal.id] = terminal
                response.terminalID = terminal.id; response.offset = 0; response.exited = false
            case .terminalRead, .terminalWrite, .terminalResize, .terminalClose:
                guard let id = request.terminalID, let terminal = terminals[id] else { throw LocalMacError("This terminal is no longer available.") }
                switch request.operation {
                case .terminalRead: response = terminal.read(offset: request.offset ?? 0); response.id = request.id
                case .terminalWrite: try terminal.write(request.data ?? Data())
                case .terminalResize: terminal.resize(width: request.width!, height: request.height!)
                case .terminalClose: terminals.removeValue(forKey: id)?.close()
                default: break
                }
            case .fileHome, .fileList, .fileStat, .fileRead, .fileUploadOpen,
                 .fileWrite, .fileUploadCommit, .fileUploadCancel, .fileMkdir, .fileRemove, .fileRename, .fileCopy:
                response = try await files.handle(request)
            }
        } catch { response.error = error.localizedDescription }
        output.send(response)
    }
    func post(_ input: LocalMacInput) throws {
        if controls == nil { controls = AccountInput(session: session) }
        try controls?.post(input, bounds: capture.bounds)
    }
    func shutdown() {
        guard !shuttingDown else { return }; shuttingDown = true
        try? controls?.post(LocalMacInput(.reset), bounds: capture.bounds)
        guardTimer?.invalidate()
        for terminal in terminals.values { terminal.close() }; terminals.removeAll()
        files.close { Darwin.exit(0) }
        // A consent dialog must not prevent Stop. Let ordinary transfer cleanup
        // drain first, but bound shutdown if a filesystem call is still blocked.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { Darwin.exit(0) }
    }
}

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--prepare-onboarding" {
    do {
        guard let data = Data(base64Encoded: arguments[2]) else { throw LocalMacError("Invalid managed account.") }
        try prepareOnboarding(JSONDecoder().decode(LocalMacAccount.self, from: data))
        exit(0)
    } catch { fputs("Managed account onboarding preparation failed.\n", stderr); exit(1) }
}
let reexecuted = arguments.count == 3 && arguments[2] == "--own-responsibility"
guard arguments.count == 2 || reexecuted, let data = Data(base64Encoded: arguments[1]),
      let session = try? JSONDecoder().decode(LocalMacSession.self, from: data), (try? session.verifyCurrent()) != nil else {
    fputs("The desktop helper must be launched in its assigned background account.\n", stderr); exit(1)
}
do {
    try prepareOnboarding(session.account)
    let executable = try standaloneDesktop(session: session, reexecuted: reexecuted)
    let responsibilityError = NLMClaimDesktopResponsibility(executable.path, arguments[1], reexecuted)
    guard responsibilityError == 0 else {
        throw LocalMacError("Cannot establish the desktop helper's permission identity (\(responsibilityError)).")
    }
} catch {
    var reply = LocalMacReply()
    reply.error = error.localizedDescription
    try? LocalMacWire.write(JSONEncoder().encode(reply), to: .standardOutput)
    exit(1)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let output = Output()
let desktop = MainActor.assumeIsolated { Desktop(session: session, output: output) }
output.onDisconnect = { [weak desktop] in desktop?.shutdown() }
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { MainActor.assumeIsolated { desktop.shutdown() } }
termination.resume()
DispatchQueue.main.async { desktop.begin() }
DispatchQueue.global().async {
    do {
        while let data = try LocalMacWire.read(.standardInput) {
            let request = try LocalMacWire.decode(LocalMacRequest.self, from: data)
            DispatchQueue.main.async { Task { await desktop.handle(request) } }
        }
    } catch {
        output.send(LocalMacReply(error: error.localizedDescription)) { desktop.shutdown() }
        return
    }
    DispatchQueue.main.async { desktop.shutdown() }
}
application.run()
