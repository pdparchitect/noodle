import Foundation
import Observation

/// A device's side of the link: the Hub it joined, and what that Hub last said it lends.
@MainActor @Observable public final class HubPairing: Identifiable {
    /// Saved when joining; enough to reach and trust the Hub again.
    public struct Hub: Codable, Equatable, Sendable {
        public var name: String
        public var key: LinkPublicKey
        public var endpoints: [LinkEndpoint]
        public var userName: String
    }

    public private(set) var hub: Hub?
    public private(set) var status: LinkStatus?
    /// The address that answered last.
    public private(set) var endpoint: LinkEndpoint?
    public private(set) var error: String?
    public private(set) var isWorking = false
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let deviceName: String

    public init(directory: URL, deviceName: String) {
        self.directory = directory
        self.deviceName = deviceName
        hub = try? JSONDecoder().decode(Hub.self, from: Data(contentsOf: hubURL))
    }

    public var keyFingerprint: String? { try? identity().publicKey.fingerprint }

    /// Pairs with the Hub the invitation names, over the same connection every later request uses.
    public func join(_ invitationText: String, now: Date = Date()) async {
        await perform {
            let invitation = try LinkInvitation(text: invitationText)
            guard invitation.expires > now else { throw LinkError("This invitation has expired. Ask for a new one.") }
            let status = try await self.exchange(.enroll(token: invitation.token, deviceName: self.deviceName),
                                                 key: invitation.hubKey, endpoints: invitation.endpoints)
            try self.save(Hub(name: status.hubName, key: invitation.hubKey, endpoints: status.endpoints, userName: status.userName))
            self.status = status
        }
    }

    /// Asks the paired Hub what it lends now. A quiet check leaves `isWorking` alone.
    public func refresh(quietly: Bool = false) async {
        guard let hub else { return }
        await perform(quietly: quietly) {
            let status = try await self.exchange(.status, key: hub.key, endpoints: hub.endpoints)
            // Left or joined another Hub while this was in flight.
            guard self.hub?.key == hub.key else { return }
            try self.save(Hub(name: status.hubName, key: hub.key, endpoints: status.endpoints, userName: status.userName))
            self.status = status
        }
    }

    public static let checkInInterval: Duration = .seconds(60)

    /// Checks in with the Hub until cancelled, which is how the Hub knows this device is connected.
    public func stayConnected() async {
        while !Task.isCancelled {
            await refresh(quietly: true)
            try? await Task.sleep(for: Self.checkInInterval)
        }
    }

    /// Forgets the Hub. The Hub still lists this device until its owner removes it.
    public func leave() {
        try? FileManager.default.removeItem(at: hubURL)
        hub = nil
        status = nil
        endpoint = nil
        error = nil
    }

    private func perform(quietly: Bool = false, _ body: () async throws -> Void) async {
        guard !isWorking else { return }
        if !quietly { isWorking = true }
        defer { if !quietly { isWorking = false } }
        do {
            try await body()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func exchange(_ request: LinkRequest, key: LinkPublicKey, endpoints: [LinkEndpoint]) async throws -> LinkStatus {
        let identity = try identity()
        let (data, endpoint) = try await LinkClient.exchange(try JSONEncoder().encode(request), identity: identity,
                                                             hubKey: key, endpoints: endpoints)
        self.endpoint = endpoint
        switch try JSONDecoder().decode(LinkResponse.self, from: data) {
        case .status(let status): return status
        case .failure(let message): throw LinkError(message)
        }
    }

    private func identity() throws -> LinkIdentity {
        try LinkIdentity.loadOrCreate(at: directory.appendingPathComponent("device.key"))
    }

    private func save(_ hub: Hub) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(hub).write(to: hubURL, options: .atomic)
        self.hub = hub
    }

    private var hubURL: URL { directory.appendingPathComponent("hub.json") }
}
