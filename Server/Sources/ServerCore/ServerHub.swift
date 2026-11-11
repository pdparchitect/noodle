#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HubCore
import HubWire
import NoodleCore
import NoodleMCP
import NoodleRuntime

/// A Hub's core as Noodle Server runs it: people, plans, bots and their tools, served over `listen`,
/// with none of what a Mac's Hub adds (computers, browsers, noodlets, calls, pictures).
@MainActor public final class ServerHub {
    public let access: HubAccess
    public let bots: HubBots
    public let link: HubLinkService
    private let repository: WorkspaceRepository
    let runtime: AgentRuntimeCoordinator
    private let usage: UsageHistory
    private let tokenLimits: HubTokenLimits

    public init(configuration: ServerConfiguration, listen: @escaping LinkListen) throws {
        let root = configuration.data
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        // Bots run the harnesses the file names, from where it says; on Linux under bubblewrap, by the server itself.
        #if os(Linux)
        let logins = ServerLogins(configuration: configuration, profiles: repository.harnessProfiles)
        runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(fixed: configuration.harnesses), harnesses: HarnessSelection(),
                                          makeProcess: { [logins] launch in
            launch.makeProcess { SandboxedHarnessConnection(workspace: launch.workspaceURL, logins: logins, profileOverride: launch.profileOverride) }
        })
        #else
        runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(fixed: configuration.harnesses), harnesses: HarnessSelection())
        #endif
        runtime.remoteModels = RemoteModelAccountStore(repository: root)
        runtime.harnessProfiles = repository.harnessProfiles
        usage = UsageHistory(url: root.appendingPathComponent("usage.sqlite"))
        access = HubAccess(url: root.appendingPathComponent("access.json"))
        access.log = HubActivityLog(url: root.appendingPathComponent("activity.jsonl"))
        try ServerAccess.apply(configuration, to: access, profiles: repository.harnessProfiles)
        tokenLimits = HubTokenLimits(access: access, usage: usage)
        // Tokens count against the plan of whoever owns the bot when it uses them.
        runtime.onUsage = { [usage, access, tokenLimits] sample in
            var sample = sample
            sample.owner = access.owner(ofBot: sample.agentID)
            usage.record(sample)
            tokenLimits.check()
        }
        runtime.recordedUsage = { [usage] in usage.recorded(session: $0) }
        access.onTokenLimitsChange = { [tokenLimits] in tokenLimits.check() }
        let connections = HubConnections(root: root, access: access, service: MCPService(namespace: "noodled"),
                                         tools: ToolProviderRegistry(), assignments: ToolAssignmentStore())
        bots = HubBots(repository: repository, runtime: self.runtime, access: access, connections: connections,
                       computers: nil, browsers: nil, applets: nil,
                       uploads: root.appendingPathComponent("Uploads", isDirectory: true), readMarks: root.appendingPathComponent("read.json"),
                       pins: root.appendingPathComponent("pins.json"), notifications: root.appendingPathComponent("notifications.json"))
        bots.tokenLimits = tokenLimits
        bots.appliesSuspensions = true
        tokenLimits.onChange = { [weak bots] in bots?.applyTokenLimits() }
        // Whoever ran out before the server last stopped stays held.
        tokenLimits.check()
        access.onSuspensionChange = { [weak bots] in bots?.synchronizeSuspensions() }
        bots.synchronizeSuspensions()
        access.onOwnersChange = { [weak bots] in
            bots?.synchronizeOwners()
            bots?.synchronizeSuspensions()
        }
        link = HubLinkService(hubName: configuration.name, directory: root.appendingPathComponent("Link", isDirectory: true),
                              access: access, profiles: HarnessProfilesController(store: repository.harnessProfiles),
                              bots: bots, connections: connections, port: configuration.port, listen: listen, network: nil,
                              localEndpoints: { ServerAddresses.local(port: $0) })
        link.manualAddress = configuration.address ?? ""
    }

    public func start() async {
        await link.start()
    }

    public func stop() {
        link.stop()
    }
}

/// Where devices on the server's networks reach it: every IPv4 address and routable IPv6 address on an
/// active interface. Loopback and link-local addresses are left out.
public enum ServerAddresses {
    public static func local(port: UInt16) -> [LinkEndpoint] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var ipv4: [String] = [], ipv6: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_RUNNING) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { continue }
                let text = String(cString: buffer)
                if !text.hasPrefix("169.254.") { ipv4.append(text) }
            case AF_INET6:
                var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                guard !(bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) != nil else { continue }
                ipv6.append(String(cString: buffer))
            default:
                continue
            }
        }
        var seen = Set<String>()
        return (ipv4 + ipv6).filter { seen.insert($0).inserted }.map { LinkEndpoint(host: $0, port: port) }
    }
}
