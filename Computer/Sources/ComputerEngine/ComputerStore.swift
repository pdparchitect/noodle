import AppKit
import ComputerBridge
import ComputerCore
import Darwin
import LocalMacCore
import Virtualization

public enum ComputerPhase: Equatable {
    case stopped, starting, running, stopping, updating
    case setupRequired(LocalMacRegistrationStatus)
    case failed(String)
    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .updating: "Upgrading…"
        case .setupRequired(let status): status == .requiresApproval ? "Approval required" : "Setup required"
        case .failed: "Needs attention"
        }
    }
    public var busy: Bool { self == .starting || self == .stopping || self == .updating }
    public var canStart: Bool {
        switch self { case .stopped, .failed, .setupRequired: true; default: false }
    }
    public var startFailureDescription: String {
        if case .failed(let reason) = self { return "Computer did not start: \(reason)" }
        if case .setupRequired(let status) = self { return LocalMacSetupRequired(registration: status).localizedDescription }
        return "Computer did not start: \(label)"
    }
}

public enum ComputerDisplayMode: String {
    case desktop = "Desktop", terminal = "Terminal", files = "Files"
    public var symbol: String {
        switch self { case .desktop: "desktopcomputer"; case .terminal: "terminal"; case .files: "folder" }
    }
}

@MainActor public final class ComputerSession: ObservableObject, Identifiable {
    public nonisolated let id: UUID
    @Published public var computer: Computer
    @Published public var phase = ComputerPhase.stopped {
        didSet { if case .failed = phase {} else { localMacSetupStatus = nil } }
    }
    @Published public var localMacSetupStatus: LocalMacRegistrationStatus?
    public var localMacSetupRequired: Bool { localMacSetupStatus != nil }
    @Published public var console = ""
    @Published public var commandRunning = false
    @Published public var updateResult: String?
    @Published public var imageUpdateAvailable = false
    public var offersImageUpgrade: Bool { computer.kind == .container && imageUpdateAvailable }
    @Published public var updateStatus: String?
    @Published public var updateProgress: Double?
    @Published public var display: NativeDisplay?
    @Published public var terminal: GuestTerminal?
    @Published public var showingTerminal = false
    @Published public var showingFiles = false
    @Published public var openingTerminal = false
    public var displayMode: ComputerDisplayMode {
        if showingFiles { return .files }
        return computer.hasDisplay && !showingTerminal ? .desktop : .terminal
    }
    public var availableDisplayModes: [ComputerDisplayMode] {
        computer.hasDisplay ? [.desktop, .terminal, .files] : [.terminal, .files]
    }
    public var canDelete: Bool {
        // A failed Local Mac connection does not prove that its account logged
        // out. The lifecycle service stops and verifies it before removal.
        if computer.kind == .localMac { return !phase.busy }
        // A start that failed has already torn down its runtime, so it can go as a
        // stopped one can. One still holding a runtime, such as a failed stop, cannot.
        let idle: Bool
        if case .failed = phase { idle = true } else { idle = phase == .stopped }
        return idle && virtual == nil && container == nil && localMac == nil && windowsRuntime == nil && sshRuntime == nil
    }
    public var virtual: VirtualComputer?
    /// A WindowsComputer, which needs macOS 27; see `windows`.
    public var windowsRuntime: AnyObject? {
        didSet {
            guard oldValue !== windowsRuntime else { return }
            fileBrowser?.disappear(); fileBrowser?.cancelTransfer(); fileBrowser = nil
            windowsTerminal?.close(); windowsTerminal = nil
            if computer.kind == .windows {
                terminal = nil; showingTerminal = false; showingFiles = false
                waitingForWindows = windowsRuntime != nil
            }
        }
    }
    @available(macOS 27, *) public var windows: WindowsComputer? { windowsRuntime as? WindowsComputer }
    /// Windows is running but its agent, which Terminal and Files need, is not there yet.
    @Published public var waitingForWindows = false
    public var windowsTerminal: WindowsTerminalConnection?
    @Published public var localMac: LocalMacComputer? {
        didSet {
            guard oldValue !== localMac else { return }
            // A retry replaces the runtime directly, without passing through nil.
            // Every surface tied to the old transport must be replaced with it.
            fileBrowser?.disappear(); fileBrowser?.cancelTransfer(); fileBrowser = nil
            localTerminal?.close(); localTerminal = nil; terminal = nil
        }
    }
    public var localTerminal: LocalMacTerminalConnection?
    public var sshRuntime: SSHComputer? {
        didSet {
            guard oldValue !== sshRuntime else { return }
            fileBrowser?.disappear(); fileBrowser?.cancelTransfer(); fileBrowser = nil
            sshTerminal?.close(); sshTerminal = nil; terminal = nil
            if sshRuntime == nil { showingTerminal = false; showingFiles = false }
        }
    }
    public var sshTerminal: SSHTerminalConnection?
    /// What the server asked to show the person while signing in, such as Tailscale's check link.
    @Published public var sshNotice: String?
    public var container: ContainerComputer? {
        didSet { if container == nil { fileBrowser?.disappear(); fileBrowser?.cancelTransfer(); fileBrowser = nil } }
    }
    private var fileBrowser: ComputerFilesModel?
    public func filesModel(for runtime: ContainerComputer) -> ComputerFilesModel {
        if let fileBrowser { return fileBrowser }
        let model = ComputerFilesModel(runtime: runtime, computerID: id)
        fileBrowser = model
        return model
    }
    public func filesModel(for runtime: LocalMacComputer) -> ComputerFilesModel {
        if let fileBrowser { return fileBrowser }
        let model = ComputerFilesModel(service: LocalMacFileService(runtime: runtime), computerID: id)
        fileBrowser = model
        return model
    }
    public func filesModel(for runtime: SSHComputer) -> ComputerFilesModel {
        if let fileBrowser { return fileBrowser }
        let model = ComputerFilesModel(service: SSHFileService(connection: runtime.connection), computerID: id, workspace: nil)
        fileBrowser = model
        return model
    }
    @available(macOS 27, *)
    public func filesModel(for runtime: WindowsComputer) -> ComputerFilesModel {
        if let fileBrowser { return fileBrowser }
        let model = ComputerFilesModel(service: WindowsFileService { [weak runtime] in runtime?.agent }, computerID: id, workspace: nil)
        fileBrowser = model
        return model
    }
    public init(_ computer: Computer) {
        self.id = computer.id
        self.computer = computer
    }
    public func sshDisconnected(_ runtime: SSHComputer, reason: String) {
        guard sshRuntime === runtime, phase == .running else { return }
        sshRuntime = nil
        phase = .failed(reason)
    }
    public func localMacDisconnected(_ runtime: LocalMacComputer, reason: String) {
        guard localMac === runtime, phase == .running || phase == .starting else { return }
        phase = .failed(reason)
    }
    public func append(_ text: String) { console = String((console + text).suffix(262_144)) }
    public func recordStartupFailure(_ error: Error) {
        if let setup = error as? LocalMacSetupRequired, setup.registration.needsSetup {
            phase = .setupRequired(setup.registration)
            return
        }
        phase = .failed(Self.outOfSpace(error) ? Self.outOfSpaceMessage : error.localizedDescription)
        localMacSetupStatus = (error as? LocalMacSetupRequired)?.registration
        append("\n\(error.localizedDescription)\n")
    }
    public static let outOfSpaceMessage = "This Mac is out of free space. Free some in Settings → Storage, then start again."
    /// Whether the error, or one it wraps, is the disk running out of space.
    public static func outOfSpace(_ error: Error) -> Bool {
        var next: NSError? = error as NSError
        while let current = next {
            if current.domain == NSPOSIXErrorDomain, current.code == Int(ENOSPC) { return true }
            if current.domain == NSCocoaErrorDomain, current.code == NSFileWriteOutOfSpaceError { return true }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

/// One owner for the library and all live machines. No provider discovery,
/// TCP listener, Noodle agent connection, shared host folders, or clipboard bridge.
@MainActor public final class ComputerStore: ObservableObject {
    public var provider: ComputerProvider?
    @Published public var sessions: [ComputerSession] = []
    @Published public var selection: UUID?
    @Published public var creationStatus: String?
    @Published public var creationProgress: Double?
    @Published public var creationDetail: String?
    @Published public var creationName = ""
    @Published public var creationLastActivity = Date()
    @Published public var creationStartedAt = Date()
    @Published public var creationCancelling = false
    public private(set) var creationWasCancelled = false
    private var creationTask: Task<Bool, Never>?
    private var creationID: UUID?
    public var imageUpdateTasks: [UUID: Task<Void, Never>] = [:]
    @Published public var storageReport: StorageReport?
    @Published public var storageBusy = false
    @Published public var storageCleaning = false
    /// What Free Up Space is doing now and how far along it is.
    @Published public var storageProgress: (label: String, fraction: Double)?
    @Published public var storageError: String?
    public var storageTask: Task<Void, Never>?
    @Published public var error: String? {
        didSet { errorRecovery = nil }
    }
    @Published public private(set) var errorRecovery: LocalMacErrorRecovery?
    public let library: ComputerLibrary
    public let cache: URL
    private let removeLocalMacAccount: (UUID) async throws -> Void
    public let sshSecrets: SSHSecretStore
    private var lease: Int32 = -1

    public init(root: URL? = nil, removeLocalMacAccount: @escaping (UUID) async throws -> Void = {
        try await LocalMacSetup.stop($0, deleting: true)
    }, sshSecrets: SSHSecretStore = .keychain) throws {
        self.removeLocalMacAccount = removeLocalMacAccount
        self.sshSecrets = sshSecrets
        // Guest I/O closure must report an error, not terminate the Mac app.
        signal(SIGPIPE, SIG_IGN)
        let location =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ComputerAppIdentity.libraryFolder, isDirectory: true)
        library = try ComputerLibrary(root: location)
        cache = location.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let fd = Darwin.open(location.appendingPathComponent("Library.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ComputerError("Cannot open the computer library lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ComputerError("This computer library is already open in another \(ComputerAppIdentity.name) process.")
        }
        lease = fd
        try? FileExportStaging.prepare()
        do { sessions = try library.load().map(ComputerSession.init) } catch {
            close(fd)
            lease = -1
            throw error
        }
        if let saved = UserDefaults.standard.string(forKey: "SelectedComputer"), let id = UUID(uuidString: saved),
            sessions.contains(where: { $0.id == id })
        {
            selection = id
        } else {
            selection = sessions.first?.id
        }
    }

    deinit { if lease >= 0 { close(lease) } }

    /// A background login can outlive a crashed or interrupted app, and an
    /// updated service may not be running. The read-only handshake starts it,
    /// so it can sign out logins that no desktop helper serves.
    public func wakeLocalMacService() {
        guard sessions.contains(where: { $0.computer.kind == .localMac }) else { return }
        Task { try? await LocalMacSetup.check() }
    }

    public var selected: ComputerSession? { sessions.first { $0.id == selection } }
    /// Reference files identify a computer; the normal library owns its UI and
    /// current terminal. Historical terminal IDs do not create another viewer.
    public func selectComputer(_ id: UUID, view: String?) throws -> ComputerSession {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ComputerError("This computer is no longer in your library.")
        }
        selection = session.id
        session.showingFiles = false
        if view == "web" { session.showingTerminal = false }
        return session
    }
    public var kernel: URL { Bundle.main.resourceURL!.appendingPathComponent("Runtime/vmlinux-arm64") }

    /// `selects` false for computers agents and the Hub make: the person stays where they are.
    public func create(_ requested: Computer, source: URL?, sshSecret: SSHSecret? = nil, selects: Bool = true) async -> Bool {
        guard !storageCleaning, creationTask == nil else { return false }
        creationID = requested.id
        creationName = requested.name
        creationStartedAt = .now
        creationWasCancelled = false
        creationCancelling = false
        error = nil
        setCreationStage("Preparing computer…")
        let task = Task { await self.performCreation(requested, source: source, sshSecret: sshSecret, selects: selects) }
        creationTask = task
        defer { creationTask = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func cancelCreation() {
        guard creationTask != nil, !creationCancelling else { return }
        creationCancelling = true
        creationTask?.cancel()
    }

    private func setCreationStage(_ status: String, progress: Double? = nil) {
        creationStatus = status
        creationProgress = progress
        creationDetail = nil
        creationLastActivity = .now
    }

    private func performCreation(_ requested: Computer, source: URL?, sshSecret: SSHSecret?, selects: Bool) async -> Bool {
        var computer = requested
        let directory = library.stagingDirectory(for: computer.id)
        let access = source?.startAccessingSecurityScopedResource() ?? false
        defer {
            if access { source?.stopAccessingSecurityScopedResource() }
            creationStatus = nil
            creationProgress = nil
            creationDetail = nil
            creationCancelling = false
            creationID = nil
        }
        do {
            try Task.checkCancellation()
            try computer.validate()
            if computer.kind == .container {
                try ContainerComputer.requireSupportedImage(computer)
            }
            try Self.requireVirtualizationLimits(computer)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            computer.macAddress = [.localMac, .ssh].contains(computer.kind) ? nil : VZMACAddress.randomLocallyAdministered().string
            if computer.kind == .ssh, let destination = computer.ssh {
                // Signing in once checks the address and sign-in, and trusts the server's key from then on.
                setCreationStage("Connecting to \(destination.host)…")
                let connection = try await SSHConnection.connect(to: destination, secret: sshSecret) { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.creationID == requested.id else { return }
                        self.creationDetail = text
                    }
                }
                connection.close()
                try Task.checkCancellation()
                computer.ssh?.hostKey = connection.hostKey
                computer.ssh?.credential = sshSecret?.credential
                if let sshSecret { try sshSecrets.save(sshSecret, computer.id) }
                computer.installationComplete = true
            } else if computer.kind == .localMac {
                // Creating a library entry does not install services or mutate
                // accounts. Start resumes the separately approved setup.
                computer.installationComplete = true
            } else if computer.kind == .container {
                guard FileManager.default.fileExists(atPath: kernel.path) else {
                    throw ComputerError(
                        "The bundled Linux kernel is missing. Rebuild \(ComputerAppIdentity.name) with its runtime resources.")
                }
                try await ContainerComputer.prepare(computer: computer, directory: directory, cache: cache) {
                    [weak self] text, update in
                    guard let owner = self else { return }
                    await MainActor.run {
                        guard owner.creationID == requested.id, !owner.creationCancelling else { return }
                        owner.setCreationStage(text, progress: update?.fraction)
                        owner.creationDetail = update?.detail
                    }
                }
                computer.installationComplete = true
            } else if computer.kind == .windows {
                guard #available(macOS 27, *) else { throw ComputerError("Windows computers need macOS 27 or later.") }
                // The first start finishes setting Windows up, so the computer is not complete until then.
                try await WindowsInstallation.prepare(computer: computer, directory: directory, cache: cache) {
                    [weak self] status, fraction, detail in
                    guard let self, self.creationID == requested.id, !self.creationCancelling else { return }
                    self.setCreationStage(status, progress: fraction)
                    self.creationDetail = detail
                }
            } else {
                if computer.kind == .macOS {
                    let restore: URL
                    if let source {
                        restore = source
                    } else {
                        setCreationStage("Finding the latest compatible macOS…")
                        let image = try await VZMacOSRestoreImage.latestSupported
                        try Task.checkCancellation()
                        let images = try RestoreImageCache(directory: cache.appendingPathComponent("Restore Images"))
                        setCreationStage("Verifying cached macOS image…")
                        let verify = Task.detached { try images.verifiedImage(for: image.url) }
                        let cached = try await withTaskCancellationHandler {
                            try await verify.value
                        } onCancel: {
                            verify.cancel()
                        }
                        if let cached {
                            restore = cached
                        } else {
                            setCreationStage("Downloading macOS…", progress: 0)
                            let reporter = DownloadProgressReporter { [weak self] update in
                                Task { @MainActor in
                                    guard let self, self.creationID == requested.id,
                                        self.creationStatus == "Downloading macOS…", !self.creationCancelling
                                    else { return }
                                    self.creationProgress = update.fraction
                                    self.creationDetail = update.detail
                                    self.creationLastActivity = .now
                                }
                            }
                            let (file, response) = try await reporter.download(for: URLRequest(url: image.url))
                            defer { try? FileManager.default.removeItem(at: file) }
                            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                                throw ComputerError("The macOS restore image download failed.")
                            }
                            try Task.checkCancellation()
                            setCreationStage("Checking the downloaded macOS image…")
                            let downloadedImage = try await VZMacOSRestoreImage.image(from: file)
                            guard downloadedImage.mostFeaturefulSupportedConfiguration != nil else {
                                throw ComputerError("The downloaded restore image is not compatible with this Mac.")
                            }
                            try Task.checkCancellation()
                            setCreationStage("Verifying and saving macOS image…")
                            let save = Task.detached { try images.store(download: file, source: image.url) }
                            restore = try await withTaskCancellationHandler {
                                try await save.value
                            } onCancel: {
                                save.cancel()
                            }
                        }
                    }
                    try Task.checkCancellation()
                    setCreationStage("Checking the macOS restore image…")
                    let image = try await VZMacOSRestoreImage.image(from: restore)
                    try Task.checkCancellation()
                    guard let requirements = image.mostFeaturefulSupportedConfiguration else {
                        throw ComputerError("This restore image is not compatible with this Mac.")
                    }
                    computer.cpuCount = max(computer.cpuCount, requirements.minimumSupportedCPUCount)
                    computer.memoryGiB = max(
                        computer.memoryGiB,
                        Int((requirements.minimumSupportedMemorySize + 1_073_741_823) / 1_073_741_824))
                    try requirements.hardwareModel.dataRepresentation.write(
                        to: directory.appendingPathComponent("HardwareModel"))
                    try VZMacMachineIdentifier().dataRepresentation.write(
                        to: directory.appendingPathComponent("MachineIdentifier"))
                    _ = try VZMacAuxiliaryStorage(
                        creatingStorageAt: directory.appendingPathComponent("AuxiliaryStorage"),
                        hardwareModel: requirements.hardwareModel, options: [])
                    try Self.createDisk(at: directory.appendingPathComponent("Disk.img"), gib: computer.diskGiB)
                    let runtime = try VirtualComputer(computer: computer, directory: directory, bootInstaller: false)
                    setCreationStage("Installing macOS…", progress: 0)
                    do {
                        try await runtime.install(from: restore) { [weak self] fraction in
                            guard let self, self.creationID == requested.id, !self.creationCancelling else { return }
                            if fraction != self.creationProgress { self.creationLastActivity = .now }
                            self.creationProgress = fraction
                        }
                        if runtime.machine.state != .stopped { try await runtime.stop() }
                    } catch {
                        if runtime.machine.state != .stopped { try? await runtime.stop() }
                        throw error
                    }
                    computer.installationComplete = true
                } else {
                    let installer: URL
                    if let source {
                        installer = source
                    } else {
                        installer = try await defaultLinuxInstaller(for: requested.id)
                    }
                    setCreationStage("Importing the installer…")
                    let destination = directory.appendingPathComponent("Installer.iso")
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.copyItem(at: installer, to: destination)
                    }.value
                    try Task.checkCancellation()
                    try Self.createDisk(at: directory.appendingPathComponent("Disk.img"), gib: computer.diskGiB)
                    _ = try VZEFIVariableStore(creatingVariableStoreAt: directory.appendingPathComponent("EFI.nvram"))
                    try VZGenericMachineIdentifier().dataRepresentation.write(
                        to: directory.appendingPathComponent("MachineIdentifier"))
                    _ = try VirtualComputer.configuration(computer, directory: directory, bootInstaller: true)
                }
            }
            try Task.checkCancellation()
            computer = try library.commit(computer)
            let session = ComputerSession(computer)
            sessions.append(session)
            if selects { selection = computer.id }
            return true
        } catch {
            creationWasCancelled = Task.isCancelled || error is CancellationError
            self.error = creationWasCancelled ? nil : error.localizedDescription
            if computer.kind == .ssh { sshSecrets.delete(computer.id) }
            // Only this operation's uncommitted UUID staging directory is removed.
            try? FileManager.default.removeItem(at: directory)
            return false
        }
    }

    private func defaultLinuxInstaller(for creation: UUID) async throws -> URL {
        let images = try RestoreImageCache(directory: cache.appendingPathComponent("Linux Images"))
        let source = DefaultLinuxInstaller.url
        let checksum = DefaultLinuxInstaller.sha256
        setCreationStage("Verifying cached Alpine Linux installer…")
        let verify = Task.detached { try images.verifiedImage(for: source, expectedSHA256: checksum) }
        let cached = try await withTaskCancellationHandler {
            try await verify.value
        } onCancel: { verify.cancel() }
        if let cached { return cached }
        setCreationStage("Downloading Alpine Linux installer…", progress: 0)
        let reporter = DownloadProgressReporter { [weak self] update in
            Task { @MainActor in
                guard let self, self.creationID == creation, !self.creationCancelling,
                      self.creationStatus == "Downloading Alpine Linux installer…" else { return }
                self.creationProgress = update.fraction
                self.creationDetail = update.detail
                self.creationLastActivity = .now
            }
        }
        let (file, response) = try await reporter.download(for: URLRequest(url: source))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ComputerError("The Alpine Linux installer download failed.")
        }
        try Task.checkCancellation()
        setCreationStage("Verifying Alpine Linux installer…")
        let save = Task.detached { try images.store(download: file, source: source, expectedSHA256: checksum) }
        return try await withTaskCancellationHandler {
            try await save.value
        } onCancel: { save.cancel() }
    }

    private static func createDisk(at url: URL, gib: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ComputerError("Cannot create the virtual disk.")
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(gib) * 1_073_741_824)
    }

    public func start(_ session: ComputerSession) async {
        guard !storageCleaning else { return }
        await startComputer(session)
    }

    public func startComputer(_ session: ComputerSession) async {
        guard !session.phase.busy, session.phase != .running else { return }
        session.showingTerminal = false
        session.showingFiles = false
        session.phase = .starting
        do {
            let computer = session.computer
            let directory = library.directory(for: computer.id)
            if computer.kind == .ssh {
                try await connectSSH(session)
            } else if computer.kind == .localMac {
                try await LocalMacSetup.check()
                var saved = computer; saved.localMacSetupRequested = true
                session.computer = try library.save(saved)
                session.localMac?.close()
                let runtime = LocalMacComputer()
                session.localMac = runtime
                runtime.onDisconnect = { [weak session, weak runtime] reason in
                    guard let runtime else { return }
                    session?.localMacDisconnected(runtime, reason: reason)
                }
                try await runtime.start(id: computer.id)
                guard runtime.isConnected else { throw ComputerError("The desktop connection closed during startup.") }
            } else if computer.kind == .windows {
                guard #available(macOS 27, *) else { throw ComputerError("Windows computers need macOS 27 or later.") }
                if let previous = session.windows, let machine = previous.machine, machine.state != .stopped {
                    throw ComputerError("Windows has not stopped yet. Use Force Stop before starting it again.")
                }
                let runtime = WindowsComputer(computer: computer, directory: directory)
                session.windowsRuntime = runtime
                runtime.onSetUp = { [weak self, weak session] in
                    guard let self, let session else { return }
                    var saved = session.computer
                    saved.installationComplete = true
                    do { session.computer = try self.library.save(saved) } catch { self.error = error.localizedDescription }
                }
                runtime.onAgentChange = { [weak session] ready in
                    guard let session else { return }
                    session.waitingForWindows = !ready
                    // Terminal and Files go with the agent, as when Windows restarts.
                    if !ready { session.showingTerminal = false; session.showingFiles = false }
                }
                runtime.onStop = { [weak session, weak runtime] error in
                    guard let session, let runtime, session.windowsRuntime === runtime else { return }
                    session.windowsRuntime = nil
                    session.phase = error.map { .failed($0.localizedDescription) } ?? .stopped
                }
                try await runtime.start()
            } else if computer.kind == .container {
                let runtime = session.container ?? ContainerComputer()
                session.container = runtime
                let text = try await runtime.start(
                    computer: computer, directory: directory, cache: cache, kernel: kernel)
                session.append(text)
                session.display = await runtime.display
                if !computer.hasDesktop {
                    let terminal = GuestTerminal()
                    session.terminal = terminal
                    try await connectTerminal(terminal, session: session, runtime: runtime)
                }
            } else {
                if let previous = session.virtual {
                    guard previous.machine.state == .stopped else {
                        throw ComputerError(
                            "The previous virtual machine has not stopped. Use Force Stop before starting it again.")
                    }
                    session.virtual = nil
                }
                let runtime = try VirtualComputer(
                    computer: computer, directory: directory, bootInstaller: !computer.installationComplete)
                session.virtual = runtime
                runtime.onStop = { [weak session, weak runtime] error in
                    guard let session, let runtime, session.virtual === runtime else { return }
                    session.phase = error.map { .failed($0.localizedDescription) } ?? .stopped
                    session.virtual = nil
                }
                try await runtime.start()
                guard runtime.machine.state == .running else {
                    throw ComputerError("The virtual machine stopped during startup.")
                }
            }
            session.phase = .running
        } catch {
            if session.computer.kind == .localMac {
                session.localMac?.close(); session.localMac = nil
            }
            if session.computer.kind == .container {
                try? await session.container?.stop()
                session.container = nil
                session.terminal = nil
                session.display = nil
            }
            if session.virtual?.machine.state == .stopped { session.virtual = nil }
            if session.computer.kind == .windows { session.windowsRuntime = nil }
            if session.computer.kind == .ssh { session.sshRuntime?.close(); session.sshRuntime = nil }
            session.recordStartupFailure(error)
        }
    }

    public func stop(_ session: ComputerSession, force: Bool = false) async {
        guard !storageCleaning else { return }
        await stopComputer(session, force: force)
    }

    public func stopComputer(_ session: ComputerSession, force: Bool = false) async {
        guard !session.phase.busy else { return }
        if #available(macOS 27, *), let windows = session.windows {
            // Windows' own runtime reports the stop, which leaves the session stopped.
            session.phase = .stopping
            if force { try? await windows.forceStop() } else { await windows.shutDown() }
            if session.windowsRuntime === windows {
                session.windowsRuntime = nil
                session.phase = .stopped
            }
            return
        }
        if let virtual = session.virtual, !force, virtual.machine.canRequestStop {
            do {
                try await Self.shutDownGuest(
                    kind: session.computer.kind, request: virtual.requestShutdown,
                    wait: { try? await Task.sleep(for: .seconds(30)) },
                    stillRunning: { session.virtual === virtual && virtual.machine.state != .stopped },
                    forceStop: { await self.stopComputer(session, force: true) })
            } catch { self.error = error.localizedDescription }
            return
        }
        session.phase = .stopping
        do {
            if session.computer.kind == .localMac {
                session.localMac?.expectDisconnect(true)
                try await LocalMacSetup.stop(session.id)
                session.localMac?.close(); session.localMac = nil
            }
            if let ssh = session.sshRuntime { ssh.close(); session.sshRuntime = nil }
            if let virtual = session.virtual, virtual.machine.state != .stopped { try await virtual.stop() }
            try await session.container?.stop()
            session.virtual = nil
            session.container = nil
            session.display = nil
            session.terminal = nil
            session.showingTerminal = false
            session.showingFiles = false
            session.phase = .stopped
        } catch {
            session.localMac?.expectDisconnect(false)
            session.phase = .failed(error.localizedDescription)
        }
    }

    public static func shutDownGuest(
        kind: ComputerKind, request: () throws -> Void, wait: () async -> Void,
        stillRunning: () -> Bool, forceStop: () async -> Void
    ) async throws {
        try request()
        // Linux guests, such as installers, may ignore the ACPI request. macOS
        // guests may be asking the user in the guest, so they are left alone.
        guard kind == .linux else { return }
        await wait()
        if stillRunning() { await forceStop() }
    }

    public func execute(_ text: String, in session: ComputerSession) async {
        guard session.phase == .running, !session.commandRunning, let runtime = session.container else { return }
        session.commandRunning = true
        session.append("\n$ \(text)\n")
        defer { session.commandRunning = false }
        do { session.append(try await runtime.execute(text)) } catch {
            session.append("\n\(error.localizedDescription)\n")
        }
    }

    /// Select an available surface without replacing its existing session.
    public func selectDisplay(_ mode: ComputerDisplayMode, in session: ComputerSession) async {
        if let runtime = session.localMac, session.phase == .running {
            guard !session.openingTerminal else { return }
            do {
                if mode == .terminal, session.localTerminal == nil {
                    session.openingTerminal = true
                    defer { session.openingTerminal = false }
                    let terminal = GuestTerminal()
                    let connection = LocalMacTerminalConnection(runtime: runtime, terminal: terminal)
                    try await connection.start()
                    guard session.localMac === runtime, session.phase == .running else {
                        connection.close()
                        return
                    }
                    session.localTerminal = connection; session.terminal = terminal
                }
                session.showingFiles = mode == .files; session.showingTerminal = mode == .terminal
            } catch {
                if session.localMac === runtime, session.phase == .running { self.error = error.localizedDescription }
            }
            return
        }
        if let ssh = session.sshRuntime, session.phase == .running {
            guard session.availableDisplayModes.contains(mode), !session.openingTerminal else { return }
            if mode == .terminal, session.sshTerminal == nil || session.sshTerminal?.ended == true {
                session.openingTerminal = true
                defer { session.openingTerminal = false }
                do { try await openSSHTerminal(session, runtime: ssh) }
                catch {
                    if session.sshRuntime === ssh { self.error = "Could not open the terminal: \(error.localizedDescription)" }
                    return
                }
            }
            session.showingFiles = mode == .files
            session.showingTerminal = mode == .terminal
            return
        }
        if #available(macOS 27, *), let windows = session.windows, session.phase == .running {
            guard session.availableDisplayModes.contains(mode) else { return }
            guard mode == .desktop || windows.agentConnected else { return }
            if mode == .terminal, session.windowsTerminal == nil || session.windowsTerminal?.ended == true {
                session.windowsTerminal?.close()
                let terminal = GuestTerminal()
                let connection = WindowsTerminalConnection(agent: windows.agent, terminal: terminal)
                connection.start()
                session.windowsTerminal = connection
                session.terminal = terminal
            }
            session.showingFiles = mode == .files
            session.showingTerminal = mode == .terminal
            return
        }
        guard session.computer.kind == .container, session.phase == .running,
              !session.openingTerminal, session.container != nil,
              session.availableDisplayModes.contains(mode), session.displayMode != mode else { return }
        switch mode {
        case .desktop:
            session.showingFiles = false
            session.showingTerminal = false
        case .terminal:
            if session.computer.hasDesktop {
                await toggleTerminal(session)
                if session.showingTerminal { session.showingFiles = false }
            } else { session.showingFiles = false }
        case .files:
            session.showingFiles = true
            session.showingTerminal = false
        }
    }

    /// A separate guest PTY, independent of the desktop processes.
    /// Keep it alive when returning to the desktop so commands/history survive.
    public func toggleTerminal(_ session: ComputerSession) async {
        guard session.computer.hasDesktop, session.phase == .running,
              !session.openingTerminal, let runtime = session.container else { return }
        if session.showingTerminal {
            session.showingTerminal = false
            return
        }
        session.openingTerminal = true
        defer { session.openingTerminal = false }
        do {
            if session.terminal == nil {
                let terminal = GuestTerminal()
                session.terminal = terminal
                try await connectTerminal(terminal, session: session, runtime: runtime)
                guard session.phase == .running, session.container === runtime else { return }
            }
            session.showingTerminal = true
        } catch {
            if session.phase == .running, session.container === runtime {
                session.terminal = nil
                self.error = "Could not open the terminal: \(error.localizedDescription)"
            }
        }
    }

    private func connectTerminal(_ terminal: GuestTerminal, session: ComputerSession, runtime: ContainerComputer) async throws {
        try await runtime.openTerminal(io: terminal.io) { [weak self, weak session, weak terminal, weak runtime] in
            // Bound rapid exits, and let an in-flight computer stop win.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let session, let terminal, let runtime else { return }
            await self.reconnectTerminal(terminal, session: session, runtime: runtime)
        }
        terminal.resize = { columns, rows in
            Task { try? await runtime.resizeTerminal(columns: columns, rows: rows) }
        }
        let screen = terminal.view.getTerminal()
        try await runtime.resizeTerminal(columns: screen.cols, rows: screen.rows)
    }

    private func reconnectTerminal(_ terminal: GuestTerminal, session: ComputerSession, runtime: ContainerComputer) async {
        guard session.container === runtime, session.terminal === terminal,
              session.phase == .running || session.phase == .starting else { return }
        terminal.reconnect()
        do {
            try await connectTerminal(terminal, session: session, runtime: runtime)
        } catch {
            guard session.container === runtime, session.phase == .running else { return }
            terminal.view.feed(text: "\r\nCould not reopen the shell: \(error.localizedDescription)\r\nPress Return to try again.\r\n")
            terminal.retryConnection = { [weak self, weak terminal, weak session, weak runtime] in
                guard let self, let terminal, let session, let runtime else { return }
                terminal.retryConnection = nil
                Task { await self.reconnectTerminal(terminal, session: session, runtime: runtime) }
            }
        }
    }

    private func connectSSH(_ session: ComputerSession) async throws {
        guard var destination = session.computer.ssh else { throw ComputerError("This computer has no address.") }
        session.sshRuntime?.close(); session.sshRuntime = nil
        session.sshNotice = nil
        defer { session.sshNotice = nil }
        let secret = destination.credential == nil ? nil : try sshSecrets.load(session.id)
        if destination.credential != nil, secret == nil {
            throw ComputerError("The Keychain no longer has this computer's key or password. Delete the computer and add it again.")
        }
        let connection = try await SSHConnection.connect(to: destination, secret: secret) { [weak session] text in
            Task { @MainActor in session?.sshNotice = text }
        }
        if destination.hostKey == nil {
            destination.hostKey = connection.hostKey
            var computer = session.computer
            computer.ssh = destination
            do { session.computer = try library.save(computer) } catch { connection.close(); throw error }
        }
        let runtime = SSHComputer(connection: connection)
        runtime.onDisconnect = { [weak session, weak runtime] reason in
            guard let session, let runtime else { return }
            session.sshDisconnected(runtime, reason: reason)
        }
        session.sshRuntime = runtime
        try await openSSHTerminal(session, runtime: runtime)
        session.showingTerminal = true
    }

    private func openSSHTerminal(_ session: ComputerSession, runtime: SSHComputer) async throws {
        session.sshTerminal?.close()
        let terminal = GuestTerminal()
        let connection = SSHTerminalConnection(connection: runtime.connection, terminal: terminal)
        try await connection.start()
        guard session.sshRuntime === runtime else { connection.close(); return }
        session.sshTerminal = connection
        session.terminal = terminal
    }

    /// Signs in with the new address and sign-in before keeping them, so a mistake leaves the old ones.
    /// A different host or port is a different server, whose key is trusted afresh.
    public func changeSignIn(_ session: ComputerSession, to address: SSHDestination, secret: SSHSecret?, keepSaved: Bool = false) async throws {
        guard let current = session.computer.ssh else { throw ComputerError("This computer has no address.") }
        var destination = address
        destination.hostKey = destination.host == current.host && destination.port == current.port ? current.hostKey : nil
        let saved = keepSaved && current.credential != nil ? try sshSecrets.load(session.id) : nil
        if keepSaved, current.credential != nil, saved == nil {
            throw ComputerError("The Keychain no longer has this computer's key or password. Choose a new sign-in.")
        }
        let used = keepSaved ? saved : secret
        let connection = try await SSHConnection.connect(to: destination, secret: used)
        connection.close()
        destination.hostKey = connection.hostKey
        destination.credential = used?.credential
        if !keepSaved {
            if let secret { try sshSecrets.save(secret, session.id) } else { sshSecrets.delete(session.id) }
        }
        var computer = session.computer
        computer.ssh = destination
        session.computer = try library.save(computer)
    }

    /// Trusts whatever key the server presents at its next sign-in.
    public func forgetServerKey(_ session: ComputerSession) {
        var computer = session.computer
        computer.ssh?.hostKey = nil
        do { session.computer = try library.save(computer) } catch { self.error = error.localizedDescription }
    }

    public func finishInstallation(_ session: ComputerSession) {
        guard session.phase == .stopped else { return }
        var computer = session.computer
        computer.installationComplete = true
        do {
            session.computer = try library.save(computer)
        } catch { self.error = error.localizedDescription }
    }

    /// Marks a computer Noodle Hub made or uses. The Hub only reaches computers it made, so
    /// one it uses that says otherwise was made before computers recorded it.
    public func note(_ session: ComputerSession, usedBy caller: String) {
        guard caller == ComputerBuildIdentity.current.hubID, session.computer.hub != true else { return }
        var computer = session.computer
        computer.hub = true
        do { session.computer = try library.save(computer) } catch { self.error = error.localizedDescription }
    }

    /// Noodle Hub saying whom one of its computers is kept for, or nobody. Only the Hub says.
    public func setHubOwner(_ session: ComputerSession, _ owner: HubOwner?, from caller: String) throws {
        guard caller == ComputerBuildIdentity.current.hubID else {
            throw ComputerBridgeError("Only Noodle Hub says whom its computers are for.")
        }
        guard session.computer.hubOwner != owner || session.computer.hub != true else { return }
        var computer = session.computer
        computer.hub = true
        computer.hubOwner = owner
        session.computer = try library.save(computer)
    }

    /// The Hub's computers under the people they are kept for, by name, then those it names nobody for.
    public static func hubGroups(_ sessions: [ComputerSession]) -> (people: [(owner: HubOwner, sessions: [ComputerSession])], unowned: [ComputerSession]) {
        let owners = sessions.compactMap(\.computer.hubOwner).reduce(into: [UUID: HubOwner]()) { $0[$1.id] = $1 }
        let people = owners.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { owner in (owner: owner, sessions: sessions.filter { $0.computer.hubOwner?.id == owner.id }) }
        return (people, sessions.filter { $0.computer.hubOwner == nil })
    }

    public func rename(_ session: ComputerSession, name: String, description: String? = nil, appearance: ComputerAppearance? = nil,
                resizesDesktop: Bool? = nil) {
        var computer = session.computer
        computer.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let description { computer.description = description }
        if let appearance { computer.appearance = appearance }
        if let resizesDesktop { computer.resizesDesktopWithWindow = resizesDesktop }
        do {
            session.computer = try library.save(computer)
        } catch { self.error = error.localizedDescription }
    }

    /// What a stopped computer runs with; it takes effect at the next start.
    public func changeResources(_ session: ComputerSession, cpus: Int, memoryGiB: Int, networkEnabled: Bool) throws {
        guard ![.localMac, .ssh].contains(session.computer.kind), session.phase == .stopped,
              session.virtual == nil, session.container == nil, session.windowsRuntime == nil else {
            throw ComputerError("Stop the computer before changing its resources.")
        }
        var computer = session.computer
        computer.cpuCount = cpus
        computer.memoryGiB = memoryGiB
        computer.networkEnabled = networkEnabled
        try Self.requireVirtualizationLimits(computer)
        session.computer = try library.save(computer)
    }

    private static func requireVirtualizationLimits(_ computer: Computer) throws {
        guard [.localMac, .ssh].contains(computer.kind) || (computer.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount &&
            UInt64(computer.memoryGiB) * 1_073_741_824 <= VZVirtualMachineConfiguration.maximumAllowedMemorySize
        ) else {
            throw ComputerError("The requested CPU or memory allocation exceeds this Mac’s virtualization limits.")
        }
    }

    public func remove(_ session: ComputerSession) {
        guard !storageCleaning, session.canDelete else { return }
        if session.computer.kind == .localMac {
            let previousPhase = session.phase
            session.phase = .stopping
            session.localMac?.expectDisconnect(true)
            Task {
                do {
                    if session.computer.localMacSetupRequested == true { try await removeLocalMacAccount(session.id) }
                    session.localMac?.close(); session.localMac = nil
                    try FileManager.default.trashItem(at: library.directory(for: session.id), resultingItemURL: nil)
                    sessions.removeAll { $0.id == session.id }
                    if selection == session.id { selection = sessions.first?.id }
                } catch {
                    session.localMac?.expectDisconnect(false)
                    session.phase = previousPhase == .running && session.localMac?.isConnected != true
                        ? .failed(error.localizedDescription) : previousPhase
                    recordRemovalFailure(error)
                }
            }
            return
        }
        do {
            // Recoverable deletion, after the UI's explicit confirmation.
            try FileManager.default.trashItem(at: library.directory(for: session.id), resultingItemURL: nil)
            if session.computer.kind == .ssh { sshSecrets.delete(session.id) }
            sessions.removeAll { $0.id == session.id }
            if selection == session.id { selection = sessions.first?.id }
        } catch { self.error = error.localizedDescription }
    }

    public func recordRemovalFailure(_ failure: Error) {
        if let removal = failure as? LocalMacRemovalFailure {
            let name = LocalMacIdentity(providerID: Bundle.main.bundleIdentifier)?.build.appName ?? "Noodle Computer"
            error = removal.message(appName: name)
            if removal.offersPrivacySettings { errorRecovery = .fullDiskAccess }
        } else if var setup = failure as? LocalMacSetupRequired {
            setup.retryAction = "Delete"
            error = setup.localizedDescription
            switch setup.registration {
            case .requiresApproval: errorRecovery = .loginItems
            case .enabled: errorRecovery = .repair
            case .notRegistered, .unknown: errorRecovery = .setup
            case .helperMissing: break
            }
        } else { error = failure.localizedDescription }
    }

    public func shutdown() async {
        storageTask?.cancel()
        await storageTask?.value
        cancelCreation()
        for task in imageUpdateTasks.values { task.cancel() }
        for task in Array(imageUpdateTasks.values) { await task.value }
        _ = await creationTask?.value
        // Windows is asked to shut down, all at once: cut off, it may boot into a repair it cannot show.
        await withTaskGroup(of: Void.self) { group in
            for session in sessions where session.windowsRuntime != nil {
                group.addTask { await self.stop(session) }
            }
        }
        for session in sessions where session.phase == .running || session.container != nil || session.virtual != nil
            || session.localMac != nil || session.windowsRuntime != nil || session.sshRuntime != nil {
            await stop(session, force: true)
        }
    }
}
