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
    /// Where this pairing keeps its key and what it knows of the Hub.
    @ObservationIgnored public let directory: URL
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

    /// Sends any request to the joined Hub, as this device.
    public func request(_ request: LinkRequest) async throws -> LinkResponse {
        guard let hub else { throw LinkError("This Mac has not joined a Noodle Hub.") }
        return try await send(request, key: hub.key, endpoints: hub.endpoints)
    }

    /// Sends a file to one of this user's conversations on the Hub, piece by piece.
    public func upload(_ file: URL, as attachment: LinkAttachment, to conversationID: UUID) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = 0
        repeat {
            let data = try handle.read(upToCount: LinkProtocol.chunkSize) ?? Data()
            _ = try await request(.upload(conversationID: conversationID, attachment: attachment, offset: offset, data: data))
            offset += data.count
        } while offset < attachment.byteCount
    }

    /// Saves one of a conversation's files from the Hub to `destination`.
    public func download(_ attachment: LinkAttachment, from conversationID: UUID, to destination: URL) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset = 0
        while true {
            guard case .chunk(let data, let total) = try await request(.download(conversationID: conversationID,
                                                                                 attachmentID: attachment.id, offset: offset)) else {
                throw LinkError("The Hub sent an unexpected answer.")
            }
            try handle.write(contentsOf: data)
            offset += data.count
            if offset >= total || data.isEmpty { break }
        }
    }

    /// Opens the stream the joined Hub pushes events down.
    public func subscribe() async throws -> AsyncThrowingStream<LinkEvent, Error> {
        guard let hub else { throw LinkError("This Mac has not joined a Noodle Hub.") }
        let subscription = try await LinkClient.subscribe(try LinkProtocol.encode(.subscribe), identity: try identity(),
                                                          hubKey: hub.key, endpoints: hub.endpoints)
        endpoint = subscription.endpoint
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await frame in subscription.frames {
                        if let event = LinkProtocol.decodeEvent(frame) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                subscription.cancel()
            }
        }
    }

    private func exchange(_ request: LinkRequest, key: LinkPublicKey, endpoints: [LinkEndpoint]) async throws -> LinkStatus {
        switch try await send(request, key: key, endpoints: endpoints) {
        case .status(let status): return status
        case .failure(let message): throw LinkError(message)
        default: throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    private func send(_ request: LinkRequest, key: LinkPublicKey, endpoints: [LinkEndpoint]) async throws -> LinkResponse {
        let (data, endpoint) = try await LinkClient.exchange(try LinkProtocol.encode(request), identity: try identity(),
                                                             hubKey: key, endpoints: endpoints)
        self.endpoint = endpoint
        let response = try LinkProtocol.decodeResponse(data)
        if case .failure(let message) = response { throw LinkError(message) }
        return response
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
