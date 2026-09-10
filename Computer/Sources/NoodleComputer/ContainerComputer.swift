// Runtime architecture follows ChatBotKit Studio (Apache-2.0): embedded
// Containerization, vminit, journaled rootfs, and NAT with guest DHCP.
import ComputerCore
import Containerization
import ContainerizationError
import ContainerizationEXT4
import ContainerizationExtras
import Foundation

final class ComputerOutput: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > 262_144 { buffer.removeFirst(buffer.count - 262_144) }
    }
    func close() throws {}
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

actor ContainerComputer {
    static let initReference = "ghcr.io/apple/containerization/vminit:0.43.0"
    private var pod: LinuxPod?
    private var commandProcess: LinuxProcess?
    private var desktopProcess: LinuxProcess?
    private var webProcess: LinuxProcess?
    private var terminalProcess: LinuxProcess?
    private var terminalIO: GuestTerminalIO?
    private var terminalID: UUID?
    private var terminalMonitor: Task<Void, Never>?
    private(set) var desktop: DesktopConnection?

    static func prepare(computer: Computer, directory: URL, cache: URL,
                        status: @escaping @Sendable (String, TransferProgress?) async -> Void) async throws {
        let store = try ImageStore(path: cache.appendingPathComponent("Images"))
        let initDisk = cache.appendingPathComponent("initfs-0.43.0.ext4")
        if !FileManager.default.fileExists(atPath: initDisk.path) {
            let label = "Downloading Linux startup files…"
            await status(label, nil)
            let progress = ImageDownloadProgress(label: label, report: status)
            let image = try await store.getInitImage(reference: initReference, progress: { await progress.update($0) })
            await status("Preparing Linux startup files…", nil)
            let staging = cache.appendingPathComponent("initfs-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: staging) }
            _ = try await image.initBlock(at: staging, for: .linuxArm)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: initDisk)
        }
        let label = computer.imageReference.hasPrefix("docker.io/library/alpine:")
            ? "Downloading Alpine Linux…" : "Downloading the workspace image…"
        await status(label, nil)
        let image: Containerization.Image
        do {
            image = try await store.get(reference: computer.imageReference)
        } catch let error as ContainerizationError where error.code == .notFound {
            let progress = ImageDownloadProgress(label: label, report: status)
            image = try await store.pull(reference: computer.imageReference, platform: .current,
                                         progress: { await progress.update($0) })
        }
        try Task.checkCancellation()
        await status("Creating your workspace disk…", nil)
        let unpackProgress = ImageDownloadProgress(label: "Creating your workspace disk…", report: status)
        _ = try await EXT4Unpacker(capacityInBytes: UInt64(computer.diskGiB) * 1_073_741_824, journal: .default)
            .unpack(image, for: .current, at: directory.appendingPathComponent("Rootfs.ext4"),
                    progress: { await unpackProgress.update($0) })
        if computer.networkEnabled {
            await status("Preparing workspace networking…", nil)
            // Separate filesystem for the one-shot network initializer, as in
            // Studio. Never mount the workspace's writable disk twice.
            let networkImage = computer.hasDesktop || computer.isCustomContainer
                ? try await store.get(reference: Computer.shellImage, pull: true) : image
            _ = try await EXT4Unpacker(capacityInBytes: 256 * 1_048_576, journal: .default)
                .unpack(networkImage, for: .current, at: directory.appendingPathComponent("Network.ext4"))
        }
        try image.digest.write(to: directory.appendingPathComponent("ImageDigest"), atomically: true, encoding: .utf8)
    }

    func start(computer: Computer, directory: URL, cache: URL, kernel: URL) async throws -> String {
        guard pod == nil else { throw ComputerError("This computer is already running.") }
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: kernel, platform: .linuxArm),
            initialFilesystem: .block(format: "ext4", source: cache.appendingPathComponent("initfs-0.43.0.ext4").path,
                                      destination: "/", options: ["ro"]))
        let interface = try CIDRv4("192.0.2.2/24")
        let runtime = try LinuxPod("computer-" + computer.id.uuidString.lowercased(), vmm: vmm) { config in
            config.cpus = computer.cpuCount
            config.memoryInBytes = UInt64(computer.memoryGiB) * 1_073_741_824
            config.hostname = "noodle-computer"
            config.bootLog = .file(path: directory.appendingPathComponent("Boot.log"))
            if computer.networkEnabled {
                config.interfaces = [NATInterface(ipv4Address: interface, ipv4Gateway: nil)]
                config.dns = DNS(nameservers: [])
            }
        }
        let output = ComputerOutput()
        if computer.networkEnabled {
            try await runtime.addContainer("network-init", rootfs: .block(format: "ext4",
                source: directory.appendingPathComponent("Network.ext4").path, destination: "/")) { config in
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
            source: directory.appendingPathComponent("Rootfs.ext4").path, destination: "/")) { config in
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
            if computer.hasDesktop {
                let address = output.text().split(separator: "\n").first { $0.hasPrefix("NOODLE_IPV4=") }?
                    .dropFirst("NOODLE_IPV4=".count)
                guard let address, (try? CIDRv4("\(address)/24")) != nil else {
                    throw ComputerError("The desktop did not receive a valid network address.")
                }
                desktop = try await launchDesktop(in: runtime, address: String(address))
                return "Linux desktop is ready."
            }
            if computer.isCustomContainer, let port = computer.webPort {
                let imageStore = try ImageStore(path: cache.appendingPathComponent("Images"))
                let image = try await imageStore.get(reference: computer.imageReference)
                guard let imageConfig = try await image.config(for: .current).config else {
                    throw ComputerError("The image has no startup configuration.")
                }
                let configured = LinuxProcessConfiguration(from: imageConfig)
                guard !configured.arguments.isEmpty else {
                    throw ComputerError("The image has no startup command for its web interface.")
                }
                let process = try await runtime.execInContainer("workspace", processID: "custom-web") { config in
                    config = configured
                    config.stdout = output
                    config.stderr = output
                }
                webProcess = process
                try await process.start()
                let address = output.text().split(separator: "\n").first { $0.hasPrefix("NOODLE_IPV4=") }?
                    .dropFirst("NOODLE_IPV4=".count)
                guard let address, (try? CIDRv4("\(address)/24")) != nil else {
                    throw ComputerError("The computer did not receive a valid network address.")
                }
                desktop = DesktopConnection(url: URL(string: "http://\(address):\(port)/")!, customWeb: true)
                return "Custom container started. Its web interface may take a moment to become ready."
            }
            return "Alpine Linux is ready. Commands run inside this computer, not on your Mac.\nWorking directory: /workspace\n" + output.text()
        } catch {
            try? await stop()
            throw error
        }
    }

    private func launchDesktop(in runtime: LinuxPod, address: String) async throws -> DesktopConnection {
        let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let environment = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/home/agent", "DISPLAY=:1", "BROWSER=chromium", "GTK_THEME=Desktop",
            "G_RESOURCE_OVERLAYS=/org/gtk/libgtk=/usr/share/launcher-desktop/gtk-overlay",
            "XAUTHORITY=/run/launcher-desktop/Xauthority", "DESKTOP_TITLE=Noodle Computer",
            "NOODLE_DESKTOP_PASSWORD=" + password]
        let setupOutput = ComputerOutput()
        let setup = try await runtime.execInContainer("workspace", processID: "desktop-security") { config in
            config.arguments = ["/bin/bash", "-c", #"""
                set -eu
                printf '127.0.0.1 localhost noodle-computer\n::1 localhost\n' > /etc/hosts
                mkdir -p /home/agent/.vnc /run/launcher-desktop
                chown agent:agent /run/launcher-desktop
                openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout /home/agent/.vnc/self.pem -out /home/agent/.vnc/self.pem -subj /CN=noodle-computer >/dev/null 2>&1
                chown -R agent:agent /home/agent/.vnc
                chmod 600 /home/agent/.vnc/self.pem
                printf '%s\n%s\n' "$NOODLE_DESKTOP_PASSWORD" "$NOODLE_DESKTOP_PASSWORD" | su -s /bin/bash -c 'HOME=/home/agent kasmvncpasswd -u agent -wo' agent >/dev/null 2>&1
                # No unauthenticated screenshot/control service on the VM network.
                chmod -x /usr/local/bin/desktop-bridge
                sed -e '/-disableBasicAuth/d' -e 's/require_ssl: false/require_ssl: true\n    pem_certificate: \/home\/agent\/.vnc\/self.pem\n    pem_key: \/home\/agent\/.vnc\/self.pem/' -e 's|curl -fsS http://127.0.0.1:6901/|curl -kfsS -u "agent:$NOODLE_DESKTOP_PASSWORD" https://127.0.0.1:6901/|g' /init > /run/noodle-desktop-init
                openssl x509 -in /home/agent/.vnc/self.pem -outform DER | base64 -w0
                """#]
            config.environmentVariables = environment
            config.stdout = setupOutput
            config.stderr = setupOutput
        }
        try await setup.start()
        let status = try await setup.wait(timeoutInSeconds: 30)
        try await setup.delete()
        guard status.exitCode == 0,
              let certificate = Data(base64Encoded: setupOutput.text().trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ComputerError("Could not secure the Linux desktop.\n" + setupOutput.text())
        }
        let output = ComputerOutput()
        let process = try await runtime.execInContainer("workspace", processID: "desktop") { config in
            config.arguments = ["/bin/bash", "/run/noodle-desktop-init"]
            config.environmentVariables = environment
            config.stdout = output
            config.stderr = output
        }
        desktopProcess = process
        try await process.start()
        let connection = DesktopConnection(url: URL(string: "https://\(address):6901/?autoconnect=1&resize=remote")!,
                                           certificate: certificate, password: password)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: DesktopSessionDelegate(connection), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var lastFailure = "No response"
        for _ in 0..<60 {
            try Task.checkCancellation()
            do {
                let (_, response) = try await session.data(from: connection.url)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return connection }
                lastFailure = "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            } catch { lastFailure = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ComputerError("The Linux desktop did not become ready: \(lastFailure)\n" + output.text())
    }

    func openTerminal(io: GuestTerminalIO, onExit: @escaping @Sendable () async -> Void = {}) async throws {
        guard let pod, terminalProcess == nil else { throw ComputerError("The terminal is not available.") }
        let id = UUID()
        terminalID = id
        let process = try await pod.execInContainer("workspace", processID: "interactive-shell-\(id.uuidString.lowercased())") { config in
            config.arguments = ["/bin/sh", "-c", "cd /workspace && exec /bin/sh -i"]
            config.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                // Expand PWD at each prompt; /bin/sh need not support Bash's \w escape.
                "HOME=/root", "TERM=xterm-256color", "PS1=${PWD} # ",
                "ENV=/etc/noodle/interactive-shell.sh"]
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
        let process = try await pod.execInContainer("workspace", processID: "noodle-\(id.uuidString.lowercased())") { config in
            config.arguments = ["/bin/sh", "-c", "cd /workspace && exec /bin/sh -i"]
            config.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME=/root", "TERM=xterm-256color", "PS1=$ ",
                "ENV=/etc/noodle/interactive-shell.sh"]
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

    func resizeTerminal(columns: Int, rows: Int) async throws {
        guard columns > 0, rows > 0 else { return }
        try await terminalProcess?.resize(to: .init(width: UInt16(clamping: columns), height: UInt16(clamping: rows)))
    }

    func execute(_ command: String) async throws -> String {
        guard let pod else { throw ComputerError("Start the computer first.") }
        guard commandProcess == nil else { throw ComputerError("A command is already running.") }
        let output = ComputerOutput()
        let process = try await pod.execInContainer("workspace", processID: UUID().uuidString.lowercased()) { config in
            config.arguments = ["/bin/sh", "-c", "cd /workspace && " + command]
            config.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root", "TERM=dumb"]
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

    func cancelCommand() async throws { try await commandProcess?.kill(.kill) }

    func stop() async throws {
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
        if let process = webProcess {
            try? await process.kill(.term)
            if (try? await process.wait(timeoutInSeconds: 3)) == nil { try? await process.kill(.kill) }
            try? await process.delete()
        }
        webProcess = nil
        desktopProcess = nil
        try? await pod.killContainer("workspace", signal: .term)
        if (try? await pod.waitContainer("workspace", timeoutInSeconds: 5)) == nil {
            try? await pod.killContainer("workspace", signal: .kill)
        }
        try await pod.stop()
        self.pod = nil
        commandProcess = nil
        desktopProcess = nil
        desktop = nil
    }
}
