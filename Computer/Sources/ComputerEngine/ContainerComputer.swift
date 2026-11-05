// Runtime architecture follows ChatBotKit Studio (Apache-2.0): embedded
// Containerization, vminit, journaled rootfs, and NAT with guest DHCP.
import ComputerCore
import Containerization
import ContainerizationError
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation

public final class ComputerOutput: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    public init() {}
    public func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > 262_144 { buffer.removeFirst(buffer.count - 262_144) }
    }
    public func close() throws {}
    public func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

public actor ContainerComputer {
    public init() {}
    static let initReference = "ghcr.io/apple/containerization/vminit:0.43.0"
    private var pod: LinuxPod?
    private var commandProcess: LinuxProcess?
    private var desktopProcess: LinuxProcess?
    private var terminalProcess: LinuxProcess?
    private var terminalIO: GuestTerminalIO?
    private var terminalID: UUID?
    private var terminalMonitor: Task<Void, Never>?
    private var guestConfiguration = LinuxProcessConfiguration()
    private(set) var display: NativeDisplay?

    static func prepare(computer: Computer, directory: URL, cache: URL,
                        status: @escaping @Sendable (String, TransferProgress?) async -> Void) async throws {
        guard let state = try await prepareImage(computer: computer, directory: directory, cache: cache,
                                                previous: nil, status: status) else {
            throw ComputerError("The computer image could not be prepared.")
        }
        try state.activate(in: directory)
    }

    public func start(computer: Computer, directory: URL, cache: URL, kernel: URL,
               preparedState: ContainerDiskState? = nil) async throws -> String {
        guard pod == nil else { throw ComputerError("This computer is already running.") }
        try Self.requireSupportedImage(computer)
        let state = try preparedState ?? ContainerDiskState.load(in: directory)
        let layers = state.directory(in: directory)
        if computer.networkEnabled, !FileManager.default.fileExists(atPath: layers.appendingPathComponent("Network.ext4").path) {
            try await Self.prepareNetworkDisk(computer: computer, layers: layers,
                                              store: ImageStore(path: cache.appendingPathComponent("Images")))
        }
        let savedImage = try JSONDecoder().decode(ContainerizationOCI.Image.self,
            from: Data(contentsOf: layers.appendingPathComponent("ImageConfig.json")))
        guestConfiguration = savedImage.config.map { LinuxProcessConfiguration(from: $0) } ?? LinuxProcessConfiguration()
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: kernel, platform: .linuxArm),
            initialFilesystem: .block(format: "ext4", source: cache.appendingPathComponent("initfs-0.43.0.ext4").path,
                                      destination: "/", options: ["ro"]))
        let interface = try CIDRv4("192.0.2.2/24")
        var display: NativeDisplay?
        if computer.hasDesktop {
            try Self.requireNativeDesktop(labels: savedImage.config?.labels)
            display = NativeDisplay { [weak self] in
                guard let self else { throw ComputerError("The computer is not running.") }
                return try await self.dialDesktopSurface()
            }
        }
        let runtime = try LinuxPod("computer-" + computer.id.uuidString.lowercased(), vmm: vmm) { config in
            if let display { config.extensions.append(display) }
            config.cpus = computer.cpuCount
            config.memoryInBytes = UInt64(computer.memoryGiB) * 1_073_741_824
            config.hostname = "noodle-computer"
            config.volumes = [
                .init(name: "noodle-base", source: .diskImage(path: layers.appendingPathComponent("Base.ext4"), readOnly: true), format: "ext4"),
                .init(name: "noodle-upper", source: .diskImage(path: layers.appendingPathComponent("Upper.ext4")), format: "ext4")
            ]
            config.bootLog = .file(path: directory.appendingPathComponent("Boot.log"))
            if computer.networkEnabled {
                config.interfaces = [NATInterface(ipv4Address: interface, ipv4Gateway: nil)]
                config.dns = DNS(nameservers: [])
            }
        }
        let output = ComputerOutput()
        if computer.networkEnabled {
            try await runtime.addContainer("network-init", rootfs: .block(format: "ext4",
                source: layers.appendingPathComponent("Network.ext4").path, destination: "/")) { config in
                config.process.arguments = ["/bin/sh", "-c", """
                    set -eu
                    ip link set eth0 up
                    attempts=0
                    while [ "$(cat /sys/class/net/eth0/carrier)" != 1 ]; do
                        attempts=$((attempts + 1))
                        if [ "$attempts" -ge 10 ]; then
                            echo 'NOODLE_NETWORK_NO_CARRIER'
                            exit 1
                        fi
                        sleep 1
                    done
                    ip address flush dev eth0
                    ip route flush dev eth0 || true
                    udhcpc -i eth0 -n -q -t 5 -T 2
                    cat /etc/resolv.conf
                    ip -4 -o addr show dev eth0 | awk '{split($4,a,"/"); print "NOODLE_IPV4=" a[1]}'
                    """]
                config.process.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
                config.process.stdout = output
                config.process.stderr = output
                var capabilities = config.process.capabilities
                capabilities.bounding.append(.netAdmin)
                capabilities.effective.append(.netAdmin)
                capabilities.permitted.append(.netAdmin)
                config.process.capabilities = capabilities
            }
        }
        try await runtime.addContainer("workspace", rootfs: .block(format: "ext4",
            source: layers.appendingPathComponent("Mount.ext4").path, destination: "/")) { config in
            config.memoryInBytes = UInt64(computer.memoryGiB) * 1_073_741_824
            config.process.arguments = ["/bin/sh", "-c", "mkdir -p /workspace; trap 'exit 0' TERM INT; while :; do sleep 1; done"]
            config.process.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root", "TERM=dumb"]
            config.process.stdout = output
            config.process.stderr = output
        }
        // Retain ownership before resource acquisition, including failed creates.
        pod = runtime
        do {
            try await runtime.create()
            try await Self.mountOverlay(in: runtime)
            try Task.checkCancellation()
            if computer.networkEnabled {
                try await runtime.startContainer("network-init")
                let status = try await runtime.waitContainer("network-init", timeoutInSeconds: 30)
                if output.text().contains("NOODLE_NETWORK_NO_CARRIER") {
                    throw ComputerError("macOS could not connect this computer’s virtual network interface. Its NAT service may need recovery. Shut down other virtual machines and restart your Mac, then try again. Your computer’s disk is unchanged.")
                }
                guard status.exitCode == 0 else { throw ComputerError("The virtual network did not provide an address. Try starting again.\n\(output.text())") }
            }
            try await runtime.startContainer("workspace")
            if computer.networkEnabled {
                let resolvers = output.text().split(separator: "\n").map(String.init).filter { $0.hasPrefix("nameserver ") }
                guard !resolvers.isEmpty else { throw ComputerError("DHCP returned no DNS servers.") }
                let process = try await runtime.execInContainer("workspace", processID: "dns-setup") { config in
                    // DHCP output is passed as arguments, never interpolated as shell code.
                    config.arguments = ["/bin/sh", "-c", "printf '%s\\n' \"$@\" > /etc/resolv.conf", "noodle-dns"] + resolvers
                    config.stdout = output
                    config.stderr = output
                }
                try await process.start()
                let status = try await process.wait(timeoutInSeconds: 10)
                try await process.delete()
                guard status.exitCode == 0 else { throw ComputerError("Could not configure workspace DNS.") }
            }
            if let display {
                try await launchDesktop(in: runtime)
                self.display = display
                return "Linux desktop is ready."
            }
            return "Alpine Linux is ready. Commands run inside this computer, not on your Mac.\nWorking directory: /workspace\n" + output.text()
        } catch {
            try? await stop()
            throw error
        }
    }

    /// Containers run only the bundled images; one made from another image cannot start.
    static func requireSupportedImage(_ computer: Computer) throws {
        guard computer.template != nil else {
            throw ComputerError("This computer uses a container image that \(ComputerAppIdentity.name) no longer supports. Move it to the Trash and create a new computer.")
        }
    }

    /// Only images built for the native display can start their desktop; older ones need an image update.
    static func requireNativeDesktop(labels: [String: String]?) throws {
        guard labels?["im.noodle.desktop.contract"] == "2" else {
            throw ComputerError("This desktop’s image is out of date. Upgrade its image to start it. Your files are kept.")
        }
    }

    private func launchDesktop(in runtime: LinuxPod) async throws {
        let output = ComputerOutput()
        let image = guestConfiguration
        // The image's supervisor runs as root and starts the session as its desktop user.
        let process = try await runtime.execInContainer("workspace", processID: "desktop") { config in
            config.arguments = ["/init"]
            config.environmentVariables = image.environmentVariables
            config.stdout = output
            config.stderr = output
        }
        desktopProcess = process
        try await process.start()
        for _ in 0..<60 {
            if output.text().contains("[desktop] ready") { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ComputerError("The Linux desktop did not start.\n" + output.text())
    }

    func dialDesktopSurface() async throws -> FileHandle {
        guard let pod else { throw ComputerError("The computer is not running.") }
        return try await pod.withVirtualMachineInstance { try await $0.dial(DesktopSurface.port) }
    }

    func openTerminal(io: GuestTerminalIO, onExit: @escaping @Sendable () async -> Void = {}) async throws {
        guard let pod, terminalProcess == nil else { throw ComputerError("The terminal is not available.") }
        let id = UUID()
        terminalID = id
        let guest = guestConfiguration
        let process = try await pod.execInContainer("workspace", processID: "interactive-shell-\(id.uuidString.lowercased())") { config in
            config.arguments = ["/bin/sh", "-c", GuestShell.command]
            config.user = guest.user
            config.environmentVariables = GuestShell.environment(inheriting: guest.environmentVariables)
            config.terminal = true
            config.stdin = io
            config.stdout = io
        }
        guard terminalID == id else {
            try? await process.delete()
            throw CancellationError()
        }
        terminalProcess = process
        terminalIO = io
        do {
            try await process.start()
            try await process.resize(to: .init(width: 80, height: 24))
            guard terminalID == id else { throw CancellationError() }
            terminalMonitor = Task { [weak self] in
                _ = try? await process.wait()
                guard !Task.isCancelled else { return }
                await self?.terminalExited(id: id, process: process, io: io, onExit: onExit)
            }
        } catch {
            try? await process.kill(.kill)
            try? await process.delete()
            if terminalID == id {
                terminalID = nil
                terminalProcess = nil
                terminalIO = nil
            }
            io.finish()
            throw error
        }
    }

    // Separate from the app's personal/recovery terminal. Each remote session
    // owns a distinct PTY, while all sessions share this computer's filesystem.
    func makeProviderTerminal(io: GuestTerminalIO, id: UUID) async throws -> LinuxProcess {
        guard let pod else { throw ComputerError("Start the computer first.") }
        let guest = guestConfiguration
        let process = try await pod.execInContainer("workspace", processID: "noodle-\(id.uuidString.lowercased())") { config in
            config.arguments = ["/bin/sh", "-c", GuestShell.command]
            config.user = guest.user
            config.environmentVariables = GuestShell.environment(inheriting: guest.environmentVariables) + [GuestShell.terminalVariable + "=" + id.uuidString.lowercased()]
            config.terminal = true; config.stdin = io; config.stdout = io
        }
        do {
            try await process.start()
            try await process.resize(to: .init(width: 100, height: 30))
            return process
        } catch {
            try? await process.kill(.kill); try? await process.delete(); io.finish()
            throw error
        }
    }

    private func terminalExited(id: UUID, process: LinuxProcess, io: GuestTerminalIO,
                                onExit: @escaping @Sendable () async -> Void) async {
        guard terminalID == id else { return }
        try? await process.delete()
        guard terminalID == id else { return }
        terminalID = nil
        terminalProcess = nil
        terminalIO = nil
        terminalMonitor = nil
        io.finish()
        await onExit()
    }

    public func resizeTerminal(columns: Int, rows: Int) async throws {
        guard columns > 0, rows > 0 else { return }
        try await terminalProcess?.resize(to: .init(width: UInt16(clamping: columns), height: UInt16(clamping: rows)))
    }

    public func execute(_ command: String) async throws -> String {
        guard let pod else { throw ComputerError("Start the computer first.") }
        guard commandProcess == nil else { throw ComputerError("A command is already running.") }
        let output = ComputerOutput()
        let guest = guestConfiguration
        let process = try await pod.execInContainer("workspace", processID: UUID().uuidString.lowercased()) { config in
            config.arguments = ["/bin/sh", "-c", "cd /workspace && " + command]
            config.user = guest.user
            config.environmentVariables = GuestShell.environment(inheriting: guest.environmentVariables, terminal: false)
            config.stdout = output
            config.stderr = output
        }
        commandProcess = process
        defer { commandProcess = nil }
        try await process.start()
        do {
            let status = try await process.wait(timeoutInSeconds: 300)
            try await process.delete()
            return output.text() + "\n[Exit \(status.exitCode)]\n"
        } catch {
            try? await process.kill(.kill)
            try? await process.delete()
            throw ComputerError("Command stopped or exceeded the five-minute limit.\n\(output.text())\n\(error.localizedDescription)")
        }
    }


    /// Whether a command runs in the foreground of provider terminal `id`, rather than its shell
    /// waiting at the prompt; nil when the guest cannot tell.
    func providerTerminalRunsCommand(_ id: UUID) async -> Bool? {
        let output = ComputerOutput()
        guard let process = try? await makeFileProcess(arguments: ["/bin/sh", "-c", GuestShell.foregroundCheck, "sh", id.uuidString.lowercased(), "/proc"],
                                                       output: output, errors: ComputerOutput()) else { return nil }
        do {
            try await process.start()
            _ = try await process.wait(timeoutInSeconds: 10)
            try? await process.delete()
        } catch {
            try? await process.kill(.kill); try? await process.delete()
            return nil
        }
        return GuestShell.runsCommand(output.text())
    }

    // Independent, non-PTY binary channel. The guest's paths are argv values.
    func makeFileProcess(arguments: [String], input: (any ReaderStream)? = nil,
                         output: any Writer, errors: any Writer) async throws -> LinuxProcess {
        guard let pod else { throw ComputerError("Start the computer to browse its files.") }
        let guest = guestConfiguration
        return try await pod.execInContainer("workspace", processID: "files-\(UUID().uuidString)") { config in
            config.arguments = arguments
            config.user = guest.user
            config.environmentVariables = GuestShell.environment(inheriting: guest.environmentVariables, terminal: false)
            config.stdin = input
            config.stdout = output
            config.stderr = errors
        }
    }

    public func stop() async throws {
        guard let pod else { return }
        // Invalidate before awaiting cleanup: an exiting shell must not reopen
        // itself while the computer is being stopped.
        terminalID = nil
        terminalMonitor?.cancel()
        terminalMonitor = nil
        terminalIO?.finish()
        if let process = terminalProcess {
            try? await process.kill(.kill)
            _ = try? await process.wait(timeoutInSeconds: 3)
            try? await process.delete()
        }
        terminalProcess = nil
        terminalIO = nil
        try? await commandProcess?.kill(.kill)
        if let process = desktopProcess {
            try? await process.kill(.term)
            if (try? await process.wait(timeoutInSeconds: 3)) == nil {
                try? await process.kill(.kill)
            }
            try? await process.delete()
        }
        desktopProcess = nil
        try? await pod.killContainer("workspace", signal: .term)
        if (try? await pod.waitContainer("workspace", timeoutInSeconds: 5)) == nil {
            try? await pod.killContainer("workspace", signal: .kill)
        }
        try? await pod.withVirtualMachineInstance { vm in
            let agent = try await vm.dialAgent()
            do { try await agent.sync(); try await agent.close() }
            catch { try? await agent.close(); throw error }
        }
        try await pod.stop()
        self.pod = nil
        commandProcess = nil
        desktopProcess = nil
        await display?.surface.close()
        display = nil
    }
}
