import BrowserBridge
import ComputerBridge
import Foundation
import HubLink
import NoodleCore
import NoodleRuntime
import Observation

/// Where paired devices reach the Hub. Every request is answered for the user whose device
/// key it arrived with, from that user's plan.
@MainActor @Observable public final class HubLinkService {
    public enum State: Equatable, Sendable {
        case stopped, starting
        case listening(port: UInt16)
        case failed(String)
    }

    public enum RouterState: Equatable, Sendable {
        case off, opening
        case open(RouterMapping)
        case failed(String)
    }

    public private(set) var state = State.stopped
    /// An address the owner knows reaches this Mac, such as a domain or a forwarded port.
    public var manualAddress: String {
        didSet { saveSettings() }
    }
    /// Whether the Hub asks the router to forward its port, for devices away from home.
    public var opensRouterPort: Bool {
        didSet {
            guard opensRouterPort != oldValue else { return }
            saveSettings()
            if opensRouterPort { Task { await openRouterPort() } } else { closeRouterPort() }
        }
    }
    public private(set) var router = RouterState.off
    public let key: LinkPublicKey
    public let hubName: String

    @ObservationIgnored private let identity: LinkIdentity
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let access: HubAccess
    @ObservationIgnored private let profiles: HarnessProfilesController
    @ObservationIgnored private let bots: HubBots?
    @ObservationIgnored private let connections: HubConnections?
    @ObservationIgnored private let computers: HubComputers?
    @ObservationIgnored private let browsers: HubBrowsers?
    /// Open event streams, by the key of the device holding each.
    @ObservationIgnored private var streams: [ObjectIdentifier: LinkStream] = [:]
    @ObservationIgnored private let port: UInt16
    @ObservationIgnored private let localEndpoints: (UInt16) -> [LinkEndpoint]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var server: LinkServer?
    @ObservationIgnored private let routerMapper: (any RouterPortMapper)?
    /// Keeps the router's port open until cancelled.
    @ObservationIgnored private var routerRenewal: Task<Void, Never>?
    /// Token digests of unused invitations. Kept in memory: an invitation outlives no relaunch.
    @ObservationIgnored private var invitations: [Data: (user: UUID, expires: Date)] = [:]

    private struct Settings: Codable {
        var manualAddress: String
        var opensRouterPort: Bool?
    }

    public init(hubName: String, directory: URL, access: HubAccess, profiles: HarnessProfilesController,
                bots: HubBots? = nil, connections: HubConnections? = nil, computers: HubComputers? = nil,
                browsers: HubBrowsers? = nil,
                port: UInt16 = LinkEndpoint.defaultPort, router: (any RouterPortMapper)? = nil,
                localEndpoints: @escaping (UInt16) -> [LinkEndpoint] = LinkEndpoint.local(port:),
                now: @escaping () -> Date = Date.init) {
        self.hubName = hubName
        self.directory = directory
        self.access = access
        self.profiles = profiles
        self.bots = bots
        self.connections = connections
        self.computers = computers
        self.browsers = browsers
        self.port = port
        routerMapper = router
        self.localEndpoints = localEndpoints
        self.now = now
        // A Hub that cannot keep its key cannot be paired with; a fresh key each launch would say so loudly.
        identity = (try? LinkIdentity.loadOrCreate(at: directory.appendingPathComponent("hub.key"))) ?? LinkIdentity()
        key = identity.publicKey
        let settings = try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: directory.appendingPathComponent("link.json")))
        manualAddress = settings?.manualAddress ?? ""
        opensRouterPort = settings?.opensRouterPort ?? true
        bots?.onChange = { [weak self] user, event in self?.push(event, to: user) }
        connections?.onSignInEnded = { [weak self] user in self?.push(.connectionsChanged, to: user) }
    }

    public func start() async {
        guard server == nil else { return }
        state = .starting
        do {
            let server = try LinkServer(identity: identity, port: port) { [weak self] key, request in
                await self?.reply(to: request, from: key) ?? .response(Data())
            }
            try await server.start()
            self.server = server
            state = .listening(port: server.port ?? port)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        await openRouterPort()
    }

    public func stop() {
        closeRouterPort()
        streams.values.forEach { $0.close() }
        streams.removeAll()
        server?.stop()
        server = nil
        state = .stopped
    }

    /// What invitations and paired devices are told to try, in order.
    public var endpoints: [LinkEndpoint] {
        var endpoints = localEndpoints(listeningPort)
        if case .open(let mapping) = router { endpoints.append(mapping.endpoint) }
        if let manualEndpoint, !endpoints.contains(manualEndpoint) { endpoints.append(manualEndpoint) }
        return endpoints
    }

    /// The manual address, with this Hub's port when it names none.
    public var manualEndpoint: LinkEndpoint? { LinkEndpoint(text: manualAddress, defaultPort: listeningPort) }

    private var listeningPort: UInt16 {
        if case .listening(let port) = state { port } else { port }
    }

    /// Noodle checks in every minute while it runs, so a device quiet for longer is gone.
    public static let presenceWindow: TimeInterval = 90

    public func isConnected(_ device: HubDevice) -> Bool {
        if streams.values.contains(where: { $0.peer == device.key }) { return true }
        guard let lastSeen = device.lastSeen else { return false }
        return now().timeIntervalSince(lastSeen) <= Self.presenceWindow
    }

    public var connectedDevices: [HubDevice] { access.devices.filter(isConnected) }

    public var connectedUsers: [HubUser] {
        let ids = Set(connectedDevices.map(\.user))
        return access.users.filter { ids.contains($0.id) }
    }

    public func invite(_ user: HubUser) -> LinkInvitation {
        let token = LinkInvitation.newToken()
        let expires = now().addingTimeInterval(LinkInvitation.lifetime)
        invitations = invitations.filter { $0.value.expires > now() }
        invitations[LinkInvitation.tokenDigest(token)] = (user.id, expires)
        return LinkInvitation(hubName: hubName, hubKey: key, endpoints: endpoints, userName: user.name,
                              token: token, expires: expires)
    }

    private func reply(to data: Data, from key: LinkPublicKey) async -> LinkReply {
        let request: LinkRequest
        switch LinkProtocol.decode(data) {
        case .success(let decoded): request = decoded
        case .failure(let error): return .response(LinkProtocol.encode(LinkResponse.failure(error.message)))
        }
        if case .subscribe = request {
            guard let device = access.device(for: key) else {
                return .response(LinkProtocol.encode(LinkResponse.failure("This device is not paired with \(hubName).")))
            }
            access.markSeen(device, at: now())
            return .stream { [weak self] stream in
                Task { @MainActor in self?.register(stream) }
            }
        }
        let response: LinkResponse
        do {
            response = try await handle(request, from: key)
        } catch {
            response = .failure(error.localizedDescription)
        }
        return .response(LinkProtocol.encode(response))
    }

    private func register(_ stream: LinkStream) {
        let id = ObjectIdentifier(stream)
        streams[id] = stream
        stream.onClose { [weak self] in
            Task { @MainActor in self?.streams[id] = nil }
        }
    }

    private func push(_ event: LinkEvent, toDevice key: LinkPublicKey) -> Bool {
        guard let stream = streams.values.first(where: { $0.peer == key && !$0.isClosed }) else { return false }
        stream.send(LinkProtocol.encode(event))
        return true
    }

    private func push(_ event: LinkEvent, to user: UUID) {
        let keys = Set(access.devices.filter { $0.user == user }.map(\.key))
        let payload = LinkProtocol.encode(event)
        for stream in streams.values where keys.contains(stream.peer) { stream.send(payload) }
    }

    private func handle(_ request: LinkRequest, from key: LinkPublicKey) async throws -> LinkResponse {
        switch request {
        case .enroll(let token, let deviceName):
            let digest = LinkInvitation.tokenDigest(token)
            guard let invitation = invitations.removeValue(forKey: digest), invitation.expires > now(),
                  let user = access.users.first(where: { $0.id == invitation.user }) else {
                throw LinkError("This invitation is no longer valid. Ask for a new one.")
            }
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let device = access.addDevice(named: name.isEmpty ? "Device" : String(name.prefix(80)), key: key, for: user, at: now())
            return .status(status(for: device))
        case .status:
            let device = try paired(key)
            access.markSeen(device, at: now())
            return .status(status(for: device))
        case .subscribe:
            throw LinkError("Subscriptions open a stream.")
        case .bots:
            return .bots(try hubBots().bots(for: try user(key)))
        case .createBot(let draft):
            return .bot(try hubBots().create(draft, for: try user(key)))
        case .updateBot(let id, let draft):
            return .bot(try hubBots().update(id, with: draft, for: try user(key)))
        case .deleteBot(let id):
            try hubBots().delete(id, for: try user(key))
            return .done
        case .messages(let conversationID, let after):
            return .messages(try hubBots().messages(in: conversationID, after: after, for: try user(key)))
        case .send(let message):
            return .message(try hubBots().send(message.body, id: message.id, attachmentIDs: message.attachmentIDs,
                                               in: message.conversationID, for: try user(key)))
        case .upload(let conversationID, let attachment, let offset, let data):
            try hubBots().receive(data, at: offset, of: attachment, in: conversationID, for: try user(key))
            return .done
        case .download(let conversationID, let attachmentID, let offset):
            let (data, total) = try hubBots().chunk(of: attachmentID, in: conversationID, at: offset, for: try user(key))
            return .chunk(data: data, total: total)
        case .react(let change):
            return .message(try hubBots().react(change, for: try user(key)))
        case .connections:
            return .connections(try hubConnections().link(for: try user(key)))
        case .saveConnection(let draft):
            let user = try user(key)
            let record = try MCPConnectionRecord(id: draft.id, name: draft.name, endpoint: draft.endpoint,
                                                 description: draft.description, instructions: draft.instructions)
            try hubConnections().add(record, for: user)
            push(.connectionsChanged, to: user.id)
            return .connection(try hubConnections().link(for: user).first { $0.id == draft.id } ?? {
                throw LinkError("The connection was saved but could not be read back.")
            }())
        case .deleteConnection(let id):
            let user = try user(key)
            try hubConnections().remove(id, for: user)
            push(.connectionsChanged, to: user.id)
            return .done
        case .assignConnections(let botID, let connectionIDs):
            let user = try user(key)
            try hubConnections().assign(Set(connectionIDs), to: botID, for: user)
            push(.connectionsChanged, to: user.id)
            return .done
        case .signIn(let connectionID, let redirect):
            try hubConnections().signIn(connectionID, redirect: redirect, for: try user(key)) { [weak self] url in
                self?.push(.signInPage(connectionID: connectionID, url: url), toDevice: key) ?? false
            }
            return .done
        case .finishSignIn(let connectionID, let callback):
            try hubConnections().finishSignIn(connectionID, callback: callback, for: try user(key))
            return .done
        case .computers:
            let computers = try hubComputers()
            await computers.refresh()
            return .computers(computers.link(for: try user(key)))
        case .computerTemplates:
            return .computerTemplates(try await hubComputers().templates().map {
                LinkComputerTemplate(id: $0.id, name: $0.name, description: $0.description, symbol: $0.symbol)
            })
        case .createComputer(let requestID, let draft):
            let computers = try hubComputers(), user = try user(key)
            Task { [weak self] in
                do {
                    let made = try await computers.create(ComputerDraft(draft), for: user)
                    self?.push(.computerCreated(requestID: requestID, computer: computers.link(made, for: user), error: nil), to: user.id)
                    self?.push(.computersChanged, to: user.id)
                } catch {
                    self?.push(.computerCreated(requestID: requestID, computer: nil, error: error.localizedDescription), to: user.id)
                }
            }
            return .done
        case .updateComputer(let id, let draft):
            let computers = try hubComputers(), user = try user(key)
            let changed = try await computers.update(id, with: ComputerDraft(draft), for: user)
            push(.computersChanged, to: user.id)
            return .computer(computers.link(changed, for: user))
        case .browsers:
            let browsers = try hubBrowsers()
            await browsers.refresh()
            return .browsers(browsers.link(for: try user(key)))
        case .createBrowser(let draft):
            let browsers = try hubBrowsers(), user = try user(key)
            let made = try await browsers.create(BrowserDraft(draft), for: user)
            push(.browsersChanged, to: user.id)
            return .browser(browsers.link(made, for: user))
        case .updateBrowser(let id, let draft):
            let browsers = try hubBrowsers(), user = try user(key)
            let changed = try await browsers.update(id, with: BrowserDraft(draft), for: user)
            push(.browsersChanged, to: user.id)
            return .browser(browsers.link(changed, for: user))
        case .deleteBrowser(let id):
            let user = try user(key)
            try await hubBrowsers().delete(id, for: user)
            push(.browsersChanged, to: user.id)
            return .done
        case .assignBrowsers(let botID, let browserIDs):
            let user = try user(key)
            try hubBrowsers().assign(Set(browserIDs), to: botID, for: user)
            push(.browsersChanged, to: user.id)
            return .done
        case .deleteComputer(let id):
            let user = try user(key)
            try await hubComputers().delete(id, for: user)
            push(.computersChanged, to: user.id)
            return .done
        case .assignComputers(let botID, let computerIDs):
            let user = try user(key)
            try hubComputers().assign(Set(computerIDs), to: botID, for: user)
            push(.computersChanged, to: user.id)
            return .done
        }
    }

    private func hubBrowsers() throws -> HubBrowsers {
        guard let browsers else { throw LinkError("This Noodle Hub does not keep browsers.") }
        return browsers
    }

    private func hubComputers() throws -> HubComputers {
        guard let computers else { throw LinkError("This Noodle Hub does not keep computers.") }
        return computers
    }

    private func hubConnections() throws -> HubConnections {
        guard let connections else { throw LinkError("This Noodle Hub does not keep tool connections.") }
        return connections
    }

    private func paired(_ key: LinkPublicKey) throws -> HubDevice {
        guard let device = access.device(for: key) else { throw LinkError("This device is not paired with \(hubName).") }
        return device
    }

    private func user(_ key: LinkPublicKey) throws -> HubUser {
        let device = try paired(key)
        guard let user = access.user(for: device) else { throw LinkError("This device is not paired with \(hubName).") }
        return user
    }

    private func hubBots() throws -> HubBots {
        guard let bots else { throw LinkError("This Noodle Hub does not keep bots.") }
        return bots
    }

    private func status(for device: HubDevice) -> LinkStatus {
        let user = access.users.first { $0.id == device.user }
        let plan = access.plans.first { $0.id == user?.plan }
        let harnesses = (plan?.harnesses ?? []).compactMap { harness -> LinkHarness? in
            var profileName: String?
            if let id = harness.profile {
                // A profile deleted outside the plan editor lends nothing.
                guard let profile = profiles.profile(id) else { return nil }
                profileName = profile.displayName
            }
            return LinkHarness(provider: harness.provider.rawValue, providerName: harness.provider.displayName,
                               profile: harness.profile, profileName: profileName)
        }
        .sorted { ($0.providerName, $0.profileName ?? "") < ($1.providerName, $1.profileName ?? "") }
        return LinkStatus(hubName: hubName, userName: user?.name ?? "", planName: plan?.name ?? "",
                          harnesses: harnesses, endpoints: endpoints)
    }

    /// Opens the port on the router, then renews it halfway through each lease, or every
    /// few minutes while the router refuses, so a router that restarts gets it back.
    private func openRouterPort() async {
        guard let routerMapper, opensRouterPort, case .listening(let port) = state, router == .off else { return }
        router = .opening
        var delay = await mapRouterPort(port, with: routerMapper)
        // Turned off, or off and on again, while the router was answering.
        guard opensRouterPort, case .listening = state, routerRenewal == nil else { return }
        routerRenewal = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                delay = await self.mapRouterPort(port, with: routerMapper)
            }
        }
    }

    /// Returns when to ask again.
    private func mapRouterPort(_ port: UInt16, with mapper: any RouterPortMapper) async -> Duration {
        do {
            let mapping = try await mapper.map(port: port)
            guard opensRouterPort, case .listening = state else {
                await mapper.unmap(mapping)
                return .zero
            }
            router = .open(mapping)
            return .seconds(mapping.lifetime > 0 ? max(60, mapping.lifetime / 2) : 1800)
        } catch {
            guard opensRouterPort else { return .zero }
            router = .failed(error.localizedDescription)
            return .seconds(300)
        }
    }

    private func closeRouterPort() {
        routerRenewal?.cancel()
        routerRenewal = nil
        if case .open(let mapping) = router, let routerMapper { Task { await routerMapper.unmap(mapping) } }
        router = .off
    }

    private func saveSettings() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Settings(manualAddress: manualAddress, opensRouterPort: opensRouterPort)).write(to: directory.appendingPathComponent("link.json"), options: .atomic)
    }
}
