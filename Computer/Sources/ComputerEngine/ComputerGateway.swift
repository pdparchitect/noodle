import ComputerCore
import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Virtualization

/// How a Linux computer reaches the network: through NAT as usual, or through a gateway that holds it to a policy.
public enum ComputerNetwork: Sendable {
    case nat
    case gateway(GatewayAttachment)
}

/// A computer's card on a gateway slot, with the addresses it gives itself there.
public struct GatewayAttachment: Sendable {
    public let interface: LinkInterface
    public let address: String
    public let gateway: String
    /// The gateway answers the computer's lookups, so names it resolves can open addresses.
    public var nameserver: String { gateway }
}

/// A small Linux machine standing between computers and NAT: each computer is cabled to one of its slots, and it
/// forwards only what its policy allows, under the computer's own address on NAT's network, so every kind of probe
/// crosses as it would through NAT. Everything else is dropped and reported through `events()`.
public actor ComputerGateway {
    /// Pinned: the gateway enforces the policy, so it changes only with the app.
    // TODO: Build our own gateway image with these packages instead of installing them on first start, once the
    // images workflow can change without breaking pending release tags.
    static let imageReference = "docker.io/library/alpine:3.23.5@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40"
    static let packages = ["nftables", "dnsmasq-dnssec-nftset", "ulogd", "ulogd-json"]
    /// Virtualization cannot add a card to a running machine, so the gateway starts with every slot cabled; it allows
    /// four cards in all, and the gateway's own way out takes one.
    // TODO: A Mission cannot hold more than three running computers behind its gateway; a frame switch in this
    // process, cabling many computers to one card, would lift the cap.
    public static let slotCount = 3

    public nonisolated let id: UUID
    private let directory: URL, cache: URL, kernel: URL
    private var pod: LinuxPod?
    private var links: [NetworkLink] = []
    private var computerEnds: [Int: FileHandle] = [:]
    public private(set) var slots: [GatewaySlot] = []
    private var occupants: [Int: UUID] = [:]
    private var upstream = ""
    private var reportedConflicts: Set<String> = []
    /// How far each log has been read, and the name each address was last looked up as.
    private var offsets: [String: Int] = [:]
    private var names: [String: String] = [:]

    /// `directory` keeps the gateway's disk, so its packages are installed once; `cache` holds the startup disk and images.
    public init(id: UUID, directory: URL, cache: URL, kernel: URL) {
        self.id = id
        self.directory = directory
        self.cache = cache
        self.kernel = kernel
    }

    public var isRunning: Bool { pod != nil }

    public func start(policy: GatewayPolicy) async throws {
        guard pod == nil else { return }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ImageStore(path: cache.appendingPathComponent("Images"))
        try await ContainerComputer.prepareInitDisk(cache: cache, store: store) { _, _ in }
        let rootfs = directory.appendingPathComponent("Gateway.ext4")
        if !files.fileExists(atPath: rootfs.path) {
            let image = try await ContainerComputer.registryRequest(reference: Self.imageReference) {
                try await store.pull(reference: Self.imageReference, platform: .current)
            }
            let staging = directory.appendingPathComponent("Gateway.partial")
            try? files.removeItem(at: staging)
            _ = try await EXT4Unpacker(capacityInBytes: 1 << 30, journal: .default).unpack(image, for: .current, at: staging)
            try files.moveItem(at: staging, to: rootfs)
        }
        var interfaces: [any Interface] = [NATInterface(ipv4Address: try CIDRv4("192.0.2.2/24"), ipv4Gateway: nil)]
        links = []
        computerEnds = [:]
        for index in 1...Self.slotCount {
            let link = try NetworkLink()
            links.append(link)
            computerEnds[index] = link.second
            interfaces.append(LinkInterface(end: link.first, ipv4Address: try CIDRv4("10.77.\(index).1/24")))
        }
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: kernel, platform: .linuxArm),
            initialFilesystem: .block(format: "ext4", source: ContainerComputer.initDisk(in: cache).path, destination: "/", options: ["ro"]))
        let runtime = try LinuxPod("gateway-" + id.uuidString.lowercased(), vmm: vmm) { config in
            config.cpus = 1
            config.memoryInBytes = 256 << 20
            config.hostname = "gateway"
            config.interfaces = interfaces
            config.dns = DNS(nameservers: [])
            config.bootLog = .file(path: self.directory.appendingPathComponent("Boot.log"))
        }
        try await runtime.addContainer("gateway", rootfs: .block(format: "ext4", source: rootfs.path, destination: "/")) { config in
            config.process.arguments = ["/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"]
            config.process.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
            config.process.capabilities = .allCapabilities
            config.sysctl = ["net.ipv4.ip_forward": "1"]
        }
        pod = runtime
        do {
            try await runtime.create()
            try await runtime.startContainer("gateway")
            // Its own way out, as a computer's network-init gets one: wait for the carrier, then DHCP from NAT.
            let lease = try await run("""
                ip link set eth0 up
                for attempt in 1 2 3 4 5 6 7 8 9 10; do [ "$(cat /sys/class/net/eth0/carrier)" = 1 ] && break; sleep 1; done
                ip address flush dev eth0
                udhcpc -i eth0 -n -q -t 5 -T 2 >/dev/null 2>&1
                ip -4 -o addr show dev eth0 | awk '{print "ADDRESS=" $4}'
                awk '/^nameserver/ {print "NAMESERVER=" $2; exit}' /etc/resolv.conf
                """)
            guard let address = Self.value("ADDRESS", in: lease), let nameserver = Self.value("NAMESERVER", in: lease) else {
                throw ComputerError("The gateway got no address from NAT.\n\(lease)")
            }
            upstream = nameserver
            _ = try await run("apk info -e \(Self.packages.joined(separator: " ")) >/dev/null || apk add -q \(Self.packages.joined(separator: " "))",
                              failure: "The gateway could not install its packages")
            let outside = try GatewayAddresses.shared.claim(Self.slotCount, network: address, owner: id)
            slots = outside.enumerated().map { GatewaySlot(index: $0.offset + 1, outsideAddress: $0.element) }
            // Fresh logs each start, so nothing is read twice.
            // TODO: What was logged in the seconds before the app quit, and not yet read, is lost at the next start.
            _ = try await run("""
                printf '%s' "$1" > /etc/ulogd.conf
                : > \(GatewayConfiguration.firewallLog); : > \(GatewayConfiguration.dnsLog)
                pkill -x ulogd; ulogd -d
                """, arguments: [GatewayConfiguration.ulogd], failure: "The gateway could not start its log")
            offsets = [:]
            names = [:]
            // Each computer's address on NAT's network answers on the gateway's own card. Announced at once: the Mac
            // remembers which machine had an address for minutes, and a gateway started again is a new machine.
            _ = try await run(slots.map { """
                ip address add \($0.outsideAddress)/32 dev eth0
                arping -U -c 2 -w 3 -I eth0 -s \($0.outsideAddress) \($0.outsideAddress) >/dev/null 2>&1 || true
                """ }.joined(separator: "\n"), failure: "The gateway could not take its computers' addresses")
            try await apply(policy)
        } catch {
            await stop()
            throw error
        }
    }

    /// Cables a computer to a free slot, or the one it already has.
    public func attach(_ computer: UUID) throws -> GatewayAttachment {
        guard pod != nil else { throw ComputerError("The gateway is not running.") }
        let index = occupants.first { $0.value == computer }?.key
            ?? (1...Self.slotCount).first { occupants[$0] == nil }
        guard let index, let end = computerEnds[index], let slot = slots.first(where: { $0.index == index }) else {
            throw ComputerError("This Mission's gateway has no free place for another computer.")
        }
        occupants[index] = computer
        return GatewayAttachment(interface: LinkInterface(end: end, ipv4Address: try CIDRv4(slot.computerAddress + "/24"),
                                                          ipv4Gateway: try IPv4Address(slot.gatewayAddress)),
                                 address: slot.computerAddress, gateway: slot.gatewayAddress)
    }

    public func detach(_ computer: UUID) {
        for (index, occupant) in occupants where occupant == computer { occupants[index] = nil }
    }

    public func occupant(ofSlot index: Int) -> UUID? { occupants[index] }

    /// Loads the policy at once; computers keep their connections.
    // TODO: Reloading forgets the addresses names resolved to, until the computers look them up again.
    public func apply(_ policy: GatewayPolicy) async throws {
        guard pod != nil else { return }
        let ruleset = GatewayConfiguration.ruleset(policy, slots: slots)
        let dns = GatewayConfiguration.dnsmasq(policy, slots: slots, upstream: upstream)
        // Passed as arguments, never interpolated as shell code.
        _ = try await run("""
            printf '%s' "$1" > /etc/gateway.nft && nft -f /etc/gateway.nft
            printf '%s' "$2" > /etc/dnsmasq.conf
            pkill -x dnsmasq; for attempt in 1 2 3 4 5; do pgrep -x dnsmasq >/dev/null || break; sleep 0.2; done
            dnsmasq
            """, arguments: [ruleset, dns], failure: "The gateway could not load its rules")
    }

    /// What its logs gained since the last call, and addresses newly shared by a denied and an allowed name.
    public func records() async throws -> GatewayRecords {
        guard pod != nil else { return GatewayRecords() }
        var records = GatewayRecords()
        let dns = try await read(GatewayConfiguration.dnsLog)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parsed = GatewayLookup.parse(dns.text, slots: slots, year: calendar.component(.year, from: Date()))
        if names.count > 100_000 { names = [:] }
        names.merge(parsed.names) { _, latest in latest }
        records.lookups = parsed.lookups
        let firewall = try await read(GatewayConfiguration.firewallLog)
        records.firewall = GatewayFirewallEntry.parse(firewall.text, slots: slots).map { entry in
            var named = entry
            named.name = names[entry.destination]
            return named
        }
        records.more = dns.more || firewall.more
        let sets = try await run("nft list set inet gateway allowed4; echo '==denied=='; nft list set inet gateway denied4")
            .components(separatedBy: "==denied==")
        if sets.count == 2 {
            let shared = Self.addresses(in: sets[0]).intersection(Self.addresses(in: sets[1])).subtracting(reportedConflicts)
            reportedConflicts.formUnion(shared)
            records.conflicts = shared.sorted()
        }
        return records
    }

    /// The whole lines a log gained since it was last read, up to a piece that fits one command's output.
    private func read(_ file: String) async throws -> (text: String, more: Bool) {
        let output = try await run("""
            size=$(stat -c %s "$1" 2>/dev/null || echo 0); offset=$2
            [ "$size" -ge "$offset" ] || offset=0
            echo "SIZE=$size OFFSET=$offset"
            tail -c +$((offset + 1)) "$1" 2>/dev/null | head -c "$3"
            """, arguments: [file, String(offsets[file] ?? 0), "200000"])
        guard let newline = output.firstIndex(of: "\n") else { return ("", false) }
        let header = output[..<newline].split(separator: " ")
        let field = { (key: String) in header.first { $0.hasPrefix(key + "=") }.flatMap { Int($0.dropFirst(key.count + 1)) } ?? 0 }
        let (text, bytes) = LogChunk.wholeLines(String(output[output.index(after: newline)...]))
        let reached = field("OFFSET") + bytes
        offsets[file] = reached
        return (text, reached < field("SIZE"))
    }

    #if NOODLE_DEV_HOOKS
    /// Runs a shell command in the gateway, for the development lab only.
    public func developmentRun(_ script: String) async throws -> String { try await run(script) }
    #endif

    public func stop() async {
        if let pod {
            try? await pod.killContainer("gateway", signal: .kill)
            try? await pod.stop()
        }
        pod = nil
        occupants = [:]
        slots = []
        links = []
        computerEnds = [:]
        reportedConflicts = []
        offsets = [:]
        names = [:]
        GatewayAddresses.shared.release(owner: id)
    }

    private func run(_ script: String, arguments: [String] = [], failure: String? = nil) async throws -> String {
        guard let pod else { throw ComputerError("The gateway is not running.") }
        let output = ComputerOutput()
        let process = try await pod.execInContainer("gateway", processID: "gateway-" + UUID().uuidString.lowercased()) { config in
            config.arguments = ["/bin/sh", "-c", script, "gateway"] + arguments
            config.environmentVariables = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]
            config.capabilities = .allCapabilities
            config.stdout = output
            config.stderr = output
        }
        try await process.start()
        let status: ExitStatus
        do { status = try await process.wait(timeoutInSeconds: 180) } catch {
            try? await process.kill(.kill)
            try? await process.delete()
            throw ComputerError((failure ?? "The gateway stopped answering") + ".\n" + output.text())
        }
        try? await process.delete()
        if let failure, status.exitCode != 0 { throw ComputerError(failure + ".\n" + output.text()) }
        return output.text()
    }

    static func value(_ key: String, in text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    static func addresses(in text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#)
        let range = NSRange(text.startIndex..., in: text)
        return Set(pattern.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }
}

/// Which addresses of NAT's network this app's gateways have given their computers, so no two take the same one.
/// They are taken from the top of the network, away from where NAT's DHCP hands out leases.
// TODO: Another app's gateways, or a lease NAT hands out from the top, could take the same address; NAT gives no
// way to reserve one, and its machines cannot see each other to check.
final class GatewayAddresses: @unchecked Sendable {
    static let shared = GatewayAddresses()
    private let lock = NSLock()
    private var taken: [String: UUID] = [:]

    /// `network` is the gateway's own address with its prefix, such as 192.168.64.3/24.
    func claim(_ count: Int, network: String, owner: UUID) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let parts = network.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix <= 30 else { throw ComputerError("NAT gave the gateway an unusable network \(network).") }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { throw ComputerError("NAT gave the gateway an unusable network \(network).") }
        let own = octets.reduce(0) { $0 << 8 | $1 }
        let mask = ~UInt32(0) << (32 - prefix)
        let broadcast = own & mask | ~mask
        var claimed: [String] = []
        var candidate = broadcast - 1
        while claimed.count < count, candidate > own & mask + 1 {
            let text = (0..<4).map { String(candidate >> (24 - 8 * $0) & 255) }.joined(separator: ".")
            if candidate != own, taken[text] == nil { claimed.append(text) }
            candidate -= 1
        }
        guard claimed.count == count else { throw ComputerError("NAT's network has no addresses left for this gateway.") }
        for address in claimed { taken[address] = owner }
        return claimed
    }

    func release(owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        taken = taken.filter { $0.value != owner }
    }
}
