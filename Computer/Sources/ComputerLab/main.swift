// Development only, never shipped: boots Linux pods through the engine's container runtime, wires their cards
// to NAT or to each other with the engine's network links, and runs commands in them, to try out how computers
// are networked. scripts/computer-lab.sh builds, signs and runs it.
//
//   computer-lab serve TOPOLOGY.json     boots the pods, then serves the commands below until down
//   computer-lab exec POD [--timeout S] -- COMMAND
//   computer-lab plug POD CARD nat|link|none
//   computer-lab down
import ComputerCore
import ComputerEngine
import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Virtualization

/// The pods and their cards. A link names a cable; exactly two cards share each name.
struct Topology: Codable {
    struct Card: Codable {
        var nat: Bool?
        var link: String?
        /// The card's address with its prefix; a NAT card gets its own from DHCP.
        var address: String?
        var gateway: String?
    }

    struct Pod: Codable {
        var name: String
        var image: String
        var cpus: Int?
        var memoryMiB: Int?
        var diskGiB: Int?
        var nameservers: [String]?
        /// Such as net.ipv4.ip_forward for a gateway; /proc/sys is otherwise read-only.
        var sysctl: [String: String]?
        var cards: [Card]
    }

    var pods: [Pod]
}

struct Request: Codable {
    var op: String
    var pod: String?
    var command: String?
    var timeout: Int?
    var card: Int?
    var plug: String?
}

struct Reply: Codable {
    var ok: Bool
    var output: String
    var exitCode: Int32?
}

struct LabError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

actor Lab {
    static let initReference = "ghcr.io/apple/containerization/vminit:0.43.0"
    let state: URL, kernel: URL
    private var pods: [String: LinuxPod] = [:]
    private var environments: [String: [String]] = [:]
    private var cards: [String: [Topology.Card]] = [:]
    private var linkCards: [String: [Int: LinkInterface]] = [:]
    private var links: [NetworkLink] = []

    init(state: URL, kernel: URL) { self.state = state; self.kernel = kernel }

    func up(_ topology: Topology) async throws {
        let files = FileManager.default
        try files.createDirectory(at: state.appendingPathComponent("Pods"), withIntermediateDirectories: true)
        let store = try ImageStore(path: state.appendingPathComponent("Images"))
        let initfs = state.appendingPathComponent("initfs-0.43.0.ext4")
        if !files.fileExists(atPath: initfs.path) {
            log("fetching the Linux startup files")
            let staging = state.appendingPathComponent("initfs.partial")
            try? files.removeItem(at: staging)
            _ = try await store.getInitImage(reference: Self.initReference).initBlock(at: staging, for: .linuxArm)
            try files.moveItem(at: staging, to: initfs)
        }
        // Each link's two ends, handed out in the order the cards name it.
        var ends: [String: [FileHandle]] = [:]
        let names = topology.pods.flatMap { $0.cards.compactMap(\.link) }
        for name in Set(names) {
            guard names.filter({ $0 == name }).count == 2 else { throw LabError("Link \(name) needs exactly two cards.") }
            let link = try NetworkLink()
            links.append(link)
            ends[name] = [link.first, link.second]
        }
        for pod in topology.pods {
            log("\(pod.name): pulling \(pod.image)")
            let image = try await store.pull(reference: pod.image, platform: .current)
            let rootfs = state.appendingPathComponent("Pods/\(pod.name).ext4")
            try? files.removeItem(at: rootfs)
            log("\(pod.name): unpacking")
            _ = try await EXT4Unpacker(capacityInBytes: UInt64(pod.diskGiB ?? 4) << 30, journal: .default)
                .unpack(image, for: .current, at: rootfs)
            let environment = try await image.config(for: .current).config?.env
                ?? ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
            var interfaces: [any Interface] = []
            for (index, card) in pod.cards.enumerated() {
                if let name = card.link {
                    guard let address = card.address else { throw LabError("\(pod.name) card \(index) needs an address.") }
                    let interface = LinkInterface(end: ends[name]!.removeFirst(), ipv4Address: try CIDRv4(address),
                                                  ipv4Gateway: try card.gateway.map { try IPv4Address($0) })
                    linkCards[pod.name, default: [:]][index] = interface
                    interfaces.append(interface)
                } else {
                    interfaces.append(NATInterface(ipv4Address: try CIDRv4(card.address ?? "192.0.2.2/24"), ipv4Gateway: nil))
                }
            }
            let vmm = VZVirtualMachineManager(kernel: Kernel(path: kernel, platform: .linuxArm),
                initialFilesystem: .block(format: "ext4", source: initfs.path, destination: "/", options: ["ro"]))
            let runtime = try LinuxPod("lab-" + pod.name, vmm: vmm) { config in
                config.cpus = pod.cpus ?? 1
                config.memoryInBytes = UInt64(pod.memoryMiB ?? 512) << 20
                config.hostname = pod.name
                config.interfaces = interfaces
                config.dns = DNS(nameservers: pod.nameservers ?? [])
                config.bootLog = .file(path: self.state.appendingPathComponent("Pods/\(pod.name).boot.log"))
            }
            try await runtime.addContainer("main", rootfs: .block(format: "ext4", source: rootfs.path, destination: "/")) { config in
                config.process.arguments = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
                config.process.environmentVariables = environment
                config.process.capabilities = .allCapabilities
                config.sysctl = pod.sysctl ?? [:]
            }
            pods[pod.name] = runtime
            environments[pod.name] = environment
            cards[pod.name] = pod.cards
            log("\(pod.name): starting")
            try await runtime.create()
            try await runtime.startContainer("main")
            for (index, card) in pod.cards.enumerated() where card.nat == true {
                let reply = try await exec(pod.name, Self.dhcp(card: index), timeout: 60)
                log("\(pod.name): eth\(index) \(reply.exitCode == 0 ? "has an address from DHCP" : "got no address")\n\(reply.output)")
            }
        }
    }

    /// As a computer's network-init does: wait for the carrier, then ask NAT's DHCP for an address and resolvers.
    static func dhcp(card: Int) -> String {
        """
        ip link set eth\(card) up
        for attempt in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat /sys/class/net/eth\(card)/carrier)" = 1 ] && break; sleep 1; done
        ip address flush dev eth\(card)
        udhcpc -i eth\(card) -n -q -t 5 -T 2
        """
    }

    func exec(_ name: String, _ command: String, timeout: Int) async throws -> Reply {
        guard let pod = pods[name] else { throw LabError("No pod called \(name).") }
        let output = ComputerOutput()
        let environment = environments[name] ?? []
        let process = try await pod.execInContainer("main", processID: "lab-" + UUID().uuidString.lowercased()) { config in
            config.arguments = ["/bin/sh", "-c", command]
            config.environmentVariables = environment
            config.capabilities = .allCapabilities
            config.stdout = output
            config.stderr = output
        }
        try await process.start()
        do {
            let status = try await process.wait(timeoutInSeconds: Int64(timeout))
            try? await process.delete()
            return Reply(ok: true, output: output.text(), exitCode: status.exitCode)
        } catch {
            try? await process.kill(.kill)
            try? await process.delete()
            return Reply(ok: false, output: output.text() + "\n[stopped: \(error.localizedDescription)]", exitCode: nil)
        }
    }

    /// Re-plugs a running pod's card into NAT, back into its link, or into nothing.
    func plug(_ name: String, card: Int, into plug: String) async throws {
        guard let pod = pods[name] else { throw LabError("No pod called \(name).") }
        let attachment: VZNetworkDeviceAttachment?
        switch plug {
        case "nat": attachment = VZNATNetworkDeviceAttachment()
        case "none": attachment = nil
        case "link":
            guard let interface = linkCards[name]?[card] else { throw LabError("Card \(card) of \(name) is not on a link.") }
            attachment = interface.attachment()
        default: throw LabError("Plug into nat, link or none.")
        }
        nonisolated(unsafe) let chosen = attachment
        try await pod.withVirtualMachineInstance { instance in
            guard let vz = instance as? VZVirtualMachineInstance else { throw LabError("Not a Virtualization machine.") }
            let machine = vz.vzVirtualMachine
            try vz.vmQueue.sync {
                guard machine.networkDevices.indices.contains(card) else { throw LabError("No card \(card).") }
                machine.networkDevices[card].attachment = chosen
            }
        }
    }

    func down() async {
        for (name, pod) in pods {
            log("\(name): stopping")
            try? await pod.killContainer("main", signal: .kill)
            try? await pod.stop()
        }
        pods = [:]
    }
}

func log(_ text: String) {
    FileHandle.standardError.write(Data(("[lab] " + text + "\n").utf8))
}

func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw LabError("Socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (index, byte) in bytes.enumerated() { raw[index] = byte }
    }
    return address
}

func readLine(_ descriptor: Int32) -> Data {
    var data = Data(), byte: UInt8 = 0
    while read(descriptor, &byte, 1) == 1 { if byte == 10 { break }; data.append(byte) }
    return data
}

func writeAll(_ descriptor: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
            if written <= 0 { return }
            offset += written
        }
    }
}

/// Answers one request per connection, each on its own thread, so a long capture does not hold up other commands.
func serve(socket path: String, lab: Lab) throws {
    unlink(path)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try socketAddress(path)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard bound == 0, listen(listener, 16) == 0 else { throw LabError("Cannot listen on \(path).") }
    print("READY \(path)")
    fflush(stdout)
    while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { continue }
        Thread.detachNewThread {
            defer { close(connection) }
            let reply: Reply
            let finished = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var answer = Reply(ok: false, output: "Unreadable request.")
            var shutdown = false
            if let request = try? JSONDecoder().decode(Request.self, from: readLine(connection)) {
                shutdown = request.op == "down"
                Task {
                    do {
                        switch request.op {
                        case "exec":
                            answer = try await lab.exec(request.pod ?? "", request.command ?? "true", timeout: request.timeout ?? 600)
                        case "plug":
                            try await lab.plug(request.pod ?? "", card: request.card ?? 0, into: request.plug ?? "")
                            answer = Reply(ok: true, output: "Plugged card \(request.card ?? 0) of \(request.pod ?? "") into \(request.plug ?? "").")
                        case "down":
                            await lab.down()
                            answer = Reply(ok: true, output: "Stopped.")
                        default:
                            answer = Reply(ok: false, output: "Unknown request \(request.op).")
                        }
                    } catch { answer = Reply(ok: false, output: error.localizedDescription) }
                    finished.signal()
                }
                finished.wait()
            }
            reply = answer
            writeAll(connection, (try? JSONEncoder().encode(reply)) ?? Data())
            if shutdown { unlink(path); exit(0) }
        }
    }
}

func send(_ request: Request, socket path: String) throws -> Reply {
    let connection = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(connection) }
    var address = try socketAddress(path)
    let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(connection, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard connected == 0 else { throw LabError("No lab is serving at \(path). Start one with serve.") }
    writeAll(connection, try JSONEncoder().encode(request) + Data([10]))
    var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(connection, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return try JSONDecoder().decode(Reply.self, from: data)
}

let environment = ProcessInfo.processInfo.environment
let state = URL(fileURLWithPath: environment["COMPUTER_LAB_STATE"] ?? ".build/computer-lab", isDirectory: true).standardizedFileURL
let socketPath = state.appendingPathComponent("lab.sock").path
var arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "serve":
        guard arguments.count == 2 else { throw LabError("serve TOPOLOGY.json") }
        guard let kernelPath = environment["COMPUTER_LAB_KERNEL"] else { throw LabError("Set COMPUTER_LAB_KERNEL to the runtime kernel.") }
        let topology = try JSONDecoder().decode(Topology.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let lab = Lab(state: state, kernel: URL(fileURLWithPath: kernelPath))
        for signal in [SIGINT, SIGTERM] {
            Foundation.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal)
            source.setEventHandler { Task { await lab.down(); unlink(socketPath); exit(0) } }
            source.resume()
            _ = Unmanaged.passRetained(source)
        }
        do { try await lab.up(topology) } catch {
            await lab.down()
            throw error
        }
        try await Task.detached { try serve(socket: socketPath, lab: lab) }.value
    case "exec":
        guard arguments.count >= 4, let separator = arguments.firstIndex(of: "--") else { throw LabError("exec POD [--timeout S] -- COMMAND") }
        var timeout = 600
        if let flag = arguments.firstIndex(of: "--timeout"), flag < separator, let value = Int(arguments[flag + 1]) { timeout = value }
        let reply = try send(Request(op: "exec", pod: arguments[1], command: arguments[(separator + 1)...].joined(separator: " "),
                                     timeout: timeout), socket: socketPath)
        print(reply.output, terminator: reply.output.hasSuffix("\n") ? "" : "\n")
        exit(reply.ok ? reply.exitCode ?? 1 : 1)
    case "plug":
        guard arguments.count == 4, let card = Int(arguments[2]) else { throw LabError("plug POD CARD nat|link|none") }
        let reply = try send(Request(op: "plug", pod: arguments[1], card: card, plug: arguments[3]), socket: socketPath)
        print(reply.output)
        exit(reply.ok ? 0 : 1)
    case "down":
        print(try send(Request(op: "down"), socket: socketPath).output)
    default:
        throw LabError("computer-lab serve TOPOLOGY.json | exec POD -- COMMAND | plug POD CARD nat|link|none | down")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
