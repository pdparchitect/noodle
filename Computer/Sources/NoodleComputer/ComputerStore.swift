import AppKit
import ComputerCore
import Darwin
import Virtualization

enum ComputerPhase: Equatable {
    case stopped, starting, running, stopping, updating
    case failed(String)
    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .updating: "Updating…"
        case .failed: "Needs attention"
        }
    }
    var busy: Bool { self == .starting || self == .stopping || self == .updating }
}

@MainActor final class ComputerSession: ObservableObject, Identifiable {
    nonisolated let id: UUID
    @Published var computer: Computer
    @Published var phase = ComputerPhase.stopped
    @Published var console = ""
    @Published var commandRunning = false
    @Published var updateResult: String?
    @Published var updateStatus: String?
    @Published var updateProgress: Double?
    @Published var desktop: DesktopConnection? {
        didSet { browser = desktop.map { ComputerDesktopBrowser(connection: $0) } }
    }
    @Published var browser: ComputerDesktopBrowser?
    @Published var terminal: GuestTerminal?
    @Published var showingTerminal = false
    @Published var openingTerminal = false
    var virtual: VirtualComputer?
    var container: ContainerComputer?
    init(_ computer: Computer) {
        self.id = computer.id
        self.computer = computer
    }
    func append(_ text: String) { console = String((console + text).suffix(262_144)) }
}

/// One owner for the library and all live machines. No provider discovery,
/// TCP listener, Noodle agent connection, shared host folders, or clipboard bridge.
@MainActor final class ComputerStore: ObservableObject {
    var provider: ComputerProvider?
    @Published var sessions: [ComputerSession] = []
    @Published var selection: UUID?
    @Published var creationStatus: String?
    @Published var creationProgress: Double?
    @Published var creationDetail: String?
    @Published var creationName = ""
    @Published var creationLastActivity = Date()
    @Published var creationStartedAt = Date()
    @Published var creationCancelling = false
    private(set) var creationWasCancelled = false
    private var creationTask: Task<Bool, Never>?
    private var creationID: UUID?
    var imageUpdateTasks: [UUID: Task<Void, Never>] = [:]
    @Published var error: String?
    let library: ComputerLibrary
    let cache: URL
    private var lease: Int32 = -1

    init(root: URL? = nil) throws {
        // Guest I/O closure must report an error, not terminate the Mac app.
        signal(SIGPIPE, SIG_IGN)
        let location =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noodle Computer", isDirectory: true)
        library = try ComputerLibrary(root: location)
        cache = location.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let fd = Darwin.open(location.appendingPathComponent("Library.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ComputerError("Cannot open the computer library lock.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ComputerError("This computer library is already open in another Noodle Computer process.")
        }
        lease = fd
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

    var selected: ComputerSession? { sessions.first { $0.id == selection } }
    var kernel: URL { Bundle.main.resourceURL!.appendingPathComponent("Runtime/vmlinux-arm64") }

    func create(_ requested: Computer, source: URL?) async -> Bool {
        guard creationTask == nil else { return false }
        creationID = requested.id
        creationName = requested.name
        creationStartedAt = .now
        creationWasCancelled = false
        creationCancelling = false
        error = nil
        setCreationStage("Preparing computer…")
        let task = Task { await self.performCreation(requested, source: source) }
        creationTask = task
        defer { creationTask = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelCreation() {
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

    private func performCreation(_ requested: Computer, source: URL?) async -> Bool {
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
            guard computer.cpuCount <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                UInt64(computer.memoryGiB) * 1_073_741_824 <= VZVirtualMachineConfiguration.maximumAllowedMemorySize
            else {
                throw ComputerError("The requested CPU or memory allocation exceeds this Mac’s virtualization limits.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            computer.macAddress = VZMACAddress.randomLocallyAdministered().string
            if computer.kind == .container {
                guard FileManager.default.fileExists(atPath: kernel.path) else {
                    throw ComputerError(
                        "The bundled Linux kernel is missing. Rebuild Noodle Computer with its runtime resources.")
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
                    } else if computer.kind == .linux {
                        installer = try await defaultLinuxInstaller(for: requested.id)
                    } else {
                        throw ComputerError("Choose a compatible ARM64 Omarchy installer in Advanced Options.")
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
            try library.commit(computer)
            let session = ComputerSession(computer)
            sessions.append(session)
            selection = computer.id
            return true
        } catch {
            creationWasCancelled = Task.isCancelled || error is CancellationError
            self.error = creationWasCancelled ? nil : error.localizedDescription
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

    func start(_ session: ComputerSession) async {
        guard !session.phase.busy, session.phase != .running else { return }
        session.showingTerminal = false
        session.phase = .starting
        do {
            let computer = session.computer
            let directory = library.directory(for: computer.id)
            if computer.kind == .container {
                let runtime = session.container ?? ContainerComputer()
                session.container = runtime
                let text = try await runtime.start(
                    computer: computer, directory: directory, cache: cache, kernel: kernel)
                session.append(text)
                session.desktop = await runtime.desktop
                if !computer.hasWebDisplay {
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
            if session.computer.kind == .container {
                try? await session.container?.stop()
                session.container = nil
                session.terminal = nil
                session.desktop = nil
            }
            if session.virtual?.machine.state == .stopped { session.virtual = nil }
            session.phase = .failed(error.localizedDescription)
            session.append("\n\(error.localizedDescription)\n")
        }
    }

    func stop(_ session: ComputerSession, force: Bool = false) async {
        guard !session.phase.busy else { return }
        if let virtual = session.virtual, !force, virtual.machine.canRequestStop {
            do { try virtual.requestShutdown() } catch { self.error = error.localizedDescription }
            return
        }
        session.phase = .stopping
        do {
            if let virtual = session.virtual, virtual.machine.state != .stopped { try await virtual.stop() }
            try await session.container?.stop()
            session.virtual = nil
            session.container = nil
            session.desktop = nil
            session.terminal = nil
            session.showingTerminal = false
            session.phase = .stopped
        } catch { session.phase = .failed(error.localizedDescription) }
    }

    func execute(_ text: String, in session: ComputerSession) async {
        guard session.phase == .running, !session.commandRunning, let runtime = session.container else { return }
        session.commandRunning = true
        session.append("\n$ \(text)\n")
        defer { session.commandRunning = false }
        do { session.append(try await runtime.execute(text)) } catch {
            session.append("\n\(error.localizedDescription)\n")
        }
    }

    /// A separate guest PTY, independent of WebKit, VNC and desktop processes.
    /// Keep it alive when returning to the desktop so commands/history survive.
    func toggleTerminal(_ session: ComputerSession) async {
        guard session.computer.hasWebDisplay, session.phase == .running,
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

    func finishInstallation(_ session: ComputerSession) {
        guard session.phase == .stopped else { return }
        var computer = session.computer
        computer.installationComplete = true
        do {
            try library.save(computer)
            session.computer = computer
        } catch { self.error = error.localizedDescription }
    }

    func rename(_ session: ComputerSession, name: String, appearance: ComputerAppearance? = nil) {
        var computer = session.computer
        computer.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let appearance { computer.appearance = appearance }
        do {
            try library.save(computer)
            session.computer = computer
        } catch { self.error = error.localizedDescription }
    }

    func remove(_ session: ComputerSession) {
        guard session.phase == .stopped, session.virtual == nil, session.container == nil else { return }
        do {
            // Recoverable deletion, after the UI's explicit confirmation.
            try FileManager.default.trashItem(at: library.directory(for: session.id), resultingItemURL: nil)
            sessions.removeAll { $0.id == session.id }
            if selection == session.id { selection = sessions.first?.id }
        } catch { self.error = error.localizedDescription }
    }

    func shutdown() async {
        cancelCreation()
        for task in imageUpdateTasks.values { task.cancel() }
        for task in Array(imageUpdateTasks.values) { await task.value }
        _ = await creationTask?.value
        for session in sessions where session.phase == .running || session.container != nil || session.virtual != nil {
            await stop(session, force: true)
        }
    }
}
