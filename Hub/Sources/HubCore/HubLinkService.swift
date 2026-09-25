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

    public private(set) var state = State.stopped
    /// An address the owner knows reaches this Mac, such as a domain or a forwarded port.
    public var manualAddress: String {
        didSet { saveSettings() }
    }
    public let key: LinkPublicKey
    public let hubName: String

    @ObservationIgnored private let identity: LinkIdentity
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let access: HubAccess
    @ObservationIgnored private let profiles: HarnessProfilesController
    @ObservationIgnored private let bots: HubBots?
    /// Open event streams, by the key of the device holding each.
    @ObservationIgnored private var streams: [ObjectIdentifier: LinkStream] = [:]
    @ObservationIgnored private let port: UInt16
    @ObservationIgnored private let localEndpoints: (UInt16) -> [LinkEndpoint]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var server: LinkServer?
    /// Token digests of unused invitations. Kept in memory: an invitation outlives no relaunch.
    @ObservationIgnored private var invitations: [Data: (user: UUID, expires: Date)] = [:]

    private struct Settings: Codable {
        var manualAddress: String
    }

    public init(hubName: String, directory: URL, access: HubAccess, profiles: HarnessProfilesController,
                bots: HubBots? = nil, port: UInt16 = LinkEndpoint.defaultPort,
                localEndpoints: @escaping (UInt16) -> [LinkEndpoint] = LinkEndpoint.local(port:),
                now: @escaping () -> Date = Date.init) {
        self.hubName = hubName
        self.directory = directory
        self.access = access
        self.profiles = profiles
        self.bots = bots
        self.port = port
        self.localEndpoints = localEndpoints
        self.now = now
        // A Hub that cannot keep its key cannot be paired with; a fresh key each launch would say so loudly.
        identity = (try? LinkIdentity.loadOrCreate(at: directory.appendingPathComponent("hub.key"))) ?? LinkIdentity()
        key = identity.publicKey
        manualAddress = (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: directory.appendingPathComponent("link.json"))))?.manualAddress ?? ""
        bots?.onChange = { [weak self] user, event in self?.push(event, to: user) }
        bots?.sendToDevice = { [weak self] key, event in self?.push(event, toDevice: key) ?? false }
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
        }
    }

    public func stop() {
        streams.values.forEach { $0.close() }
        streams.removeAll()
        server?.stop()
        server = nil
        state = .stopped
    }

    /// What invitations and paired devices are told to try, in order.
    public var endpoints: [LinkEndpoint] {
        localEndpoints(listeningPort) + (manualEndpoint.map { [$0] } ?? [])
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

    private func reply(to data: Data, from key: LinkPublicKey) -> LinkReply {
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
            response = try handle(request, from: key)
        } catch {
            response = .failure(error.localizedDescription)
        }
        return .response(LinkProtocol.encode(response))
    }

    private func register(_ stream: LinkStream) {
        let id = ObjectIdentifier(stream)
        streams[id] = stream
        stream.onClose { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.streams[id] = nil
                if !self.streams.values.contains(where: { $0.peer == stream.peer }) { self.bots?.deviceDisconnected(stream.peer) }
            }
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

    private func handle(_ request: LinkRequest, from key: LinkPublicKey) throws -> LinkResponse {
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
        case .send(let conversationID, let id, let body, let attachmentIDs):
            return .message(try hubBots().send(body, id: id, attachmentIDs: attachmentIDs, in: conversationID, for: try user(key)))
        case .upload(let conversationID, let attachment, let offset, let data):
            try hubBots().receive(data, at: offset, of: attachment, in: conversationID, for: try user(key))
            return .done
        case .download(let conversationID, let attachmentID, let offset):
            let (data, total) = try hubBots().chunk(of: attachmentID, in: conversationID, at: offset, for: try user(key))
            return .chunk(data: data, total: total)
        case .publishTools(let botID, let catalogue):
            try hubBots().publishTools(catalogue, for: botID, from: key, for: try user(key))
            return .done
        case .toolResult(let callID, let result, let error):
            _ = try user(key)
            try hubBots().finishToolCall(callID, result: result, error: error, from: key)
            return .done
        }
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

    private func saveSettings() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Settings(manualAddress: manualAddress)).write(to: directory.appendingPathComponent("link.json"), options: .atomic)
    }
}
