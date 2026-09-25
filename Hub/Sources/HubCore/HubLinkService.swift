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
                port: UInt16 = LinkEndpoint.defaultPort,
                localEndpoints: @escaping (UInt16) -> [LinkEndpoint] = LinkEndpoint.local(port:),
                now: @escaping () -> Date = Date.init) {
        self.hubName = hubName
        self.directory = directory
        self.access = access
        self.profiles = profiles
        self.port = port
        self.localEndpoints = localEndpoints
        self.now = now
        // A Hub that cannot keep its key cannot be paired with; a fresh key each launch would say so loudly.
        identity = (try? LinkIdentity.loadOrCreate(at: directory.appendingPathComponent("hub.key"))) ?? LinkIdentity()
        key = identity.publicKey
        manualAddress = (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: directory.appendingPathComponent("link.json"))))?.manualAddress ?? ""
    }

    public func start() async {
        guard server == nil else { return }
        state = .starting
        do {
            let server = try LinkServer(identity: identity, port: port) { [weak self] key, request in
                await self?.respond(to: request, from: key) ?? Data()
            }
            try await server.start()
            self.server = server
            state = .listening(port: server.port ?? port)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func stop() {
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

    private func respond(to data: Data, from key: LinkPublicKey) -> Data {
        let response: LinkResponse
        do {
            response = try handle(try JSONDecoder().decode(LinkRequest.self, from: data), from: key)
        } catch {
            response = .failure(error.localizedDescription)
        }
        return (try? JSONEncoder().encode(response)) ?? Data()
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
            guard let device = access.device(for: key) else {
                throw LinkError("This device is not paired with \(hubName).")
            }
            access.markSeen(device, at: now())
            return .status(status(for: device))
        }
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
            return LinkHarness(provider: harness.provider.rawValue, providerName: harness.provider.displayName, profileName: profileName)
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
