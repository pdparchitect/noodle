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
    /// What the Hub last said it lends, kept across launches so it shows before the Hub answers again.
    public private(set) var status: LinkStatus?
    /// This user's picture, its image filled in once this device has it. Nil shows their initials.
    public private(set) var avatar: LinkAvatar?
    /// The address that answered last.
    public private(set) var endpoint: LinkEndpoint?
    public private(set) var error: String?
    /// Whether `error` is no address of the Hub answering.
    public private(set) var isUnreachable = false
    public private(set) var isWorking = false
    /// Where this pairing keeps its key and what it knows of the Hub.
    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let deviceName: String

    public init(directory: URL, deviceName: String) {
        self.directory = directory
        self.deviceName = deviceName
        hub = try? JSONDecoder().decode(Hub.self, from: Data(contentsOf: hubURL))
        if hub != nil { status = try? LinkProtocol.decoder.decode(LinkStatus.self, from: Data(contentsOf: statusURL)) }
        avatar = keptAvatar
    }

    public var keyFingerprint: String? { try? identity().publicKey.fingerprint }

    /// Pairs with the Hub the invitation names, over the same connection every later request uses.
    public func join(_ invitationText: String, now: Date = Date()) async {
        await perform {
            let invitation = try LinkInvitation(text: invitationText)
            guard invitation.expires > now else { throw LinkError("This invitation has expired. Ask for a new one.") }
            let join = try invitation.joinIdentity(), device = try self.identity()
            let enroll = LinkRequest.enroll(deviceKey: device.publicKey, proof: try device.joinProof(for: join.publicKey),
                                            deviceName: self.deviceName)
            let status = try await self.exchange(enroll, as: join, key: invitation.hubKey, endpoints: invitation.endpoints)
            try self.save(Hub(name: status.hubName, key: invitation.hubKey, endpoints: status.endpoints, userName: status.userName))
            self.remember(status)
        }
    }

    /// Asks the paired Hub what it lends now. A quiet check leaves `isWorking` alone.
    public func refresh(quietly: Bool = false) async {
        guard let hub else { return }
        await perform(quietly: quietly) {
            let status = try await self.exchange(.status, as: try self.identity(), key: hub.key, endpoints: hub.endpoints)
            // Left or joined another Hub while this was in flight.
            guard self.hub?.key == hub.key else { return }
            try self.save(Hub(name: status.hubName, key: hub.key, endpoints: status.endpoints, userName: status.userName))
            self.remember(status)
            if let me = self.me {
                await self.fetchPictures([me])
                self.avatar = self.keptAvatar
            }
        }
    }

    /// Changes this user's picture on the Hub, or with nil shows their initials.
    public func setAvatar(_ avatar: LinkAvatar?) async throws {
        guard case .status(let status) = try await request(.setAvatar(avatar?.leavingOutKnownImage)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        if let me = Me(status), let image = avatar?.image, status.avatar?.imageDigest == LinkPicture.digest(image) {
            keep(image, for: me)
        }
        remember(status)
    }

    /// The other people on the Hub, with the pictures this device keeps of them.
    public func people() async throws -> [LinkPerson] {
        guard case .people(let people) = try await request(.people) else { throw LinkError("The Hub sent an unexpected answer.") }
        await fetchPictures(people)
        return keptPictures(people)
    }

    /// This user, whose picture is kept apart from other people's, as each list forgets what it no longer shows.
    private struct Me: LinkPictured {
        static let pictureFolder = "Me"
        var person: LinkPerson
        var pictureOwner: LinkPictureOwner { person.pictureOwner }
        var picture: Data? {
            get { person.picture }
            set { person.picture = newValue }
        }
        var pictureDigest: String? {
            get { person.pictureDigest }
            set { person.pictureDigest = newValue }
        }

        init?(_ status: LinkStatus?) {
            guard let status, let id = status.userID else { return nil }
            person = LinkPerson(id: id, name: status.userName, avatar: status.avatar)
        }
    }

    private var me: Me? { Me(status) }

    private var keptAvatar: LinkAvatar? {
        guard let me else { return status?.avatar }
        return keptPictures([me]).first?.person.avatar
    }

    public static let checkInInterval: Duration = .seconds(60)

    /// Checks in with the Hub until cancelled, which is how the Hub knows this device is connected.
    public func stayConnected() async {
        while !Task.isCancelled {
            await refresh(quietly: true)
            try? await Task.sleep(for: Self.checkInInterval)
        }
    }

    /// Forgets the Hub at once, keeping only what telling it takes until `sendLeave` has.
    public func leave() {
        if let hub { try? JSONEncoder().encode(hub).write(to: leavingURL, options: .atomic) }
        try? FileManager.default.removeItem(at: hubURL)
        try? FileManager.default.removeItem(at: statusURL)
        hub = nil
        status = nil
        avatar = nil
        endpoint = nil
        error = nil
        isUnreachable = false
    }

    /// Whether a device that left the Hub from this folder has yet to tell it.
    public static func isLeaving(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(leavingName).path)
    }

    /// Tells the Hub this device left, from the folder it kept; true once the Hub answered, whatever
    /// it said: a Hub that already forgot the device, or one too old to know the request, will not
    /// answer differently later.
    public static func sendLeave(from folder: URL) async -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(leavingName)),
              let hub = try? JSONDecoder().decode(Hub.self, from: data),
              let identity = try? LinkIdentity.loadOrCreate(at: folder.appendingPathComponent(keyName)),
              let request = try? LinkProtocol.encode(.leave) else { return true }
        do {
            _ = try await LinkClient.exchange(request, identity: identity, hubKey: hub.key, endpoints: hub.endpoints)
            return true
        } catch {
            return false
        }
    }

    private func perform(quietly: Bool = false, _ body: () async throws -> Void) async {
        guard !isWorking else { return }
        if !quietly { isWorking = true }
        defer { if !quietly { isWorking = false } }
        do {
            try await body()
            error = nil
            isUnreachable = false
        } catch is CancellationError {
            // Given up on, which says nothing about the Hub.
        } catch {
            self.error = error.localizedDescription
            isUnreachable = (error as? LinkError)?.isUnreachable == true
        }
    }

    /// Sends any request to the joined Hub, as this device.
    public func request(_ request: LinkRequest) async throws -> LinkResponse {
        guard let hub else { throw LinkError("This Mac has not joined a Noodle Hub.") }
        return try await send(request, as: try identity(), key: hub.key, endpoints: hub.endpoints)
    }

    /// How long a sign-in this device started waits for the Hub to send its page.
    public static let signInWait: TimeInterval = 5 * 60
    /// Sign-ins this device started, by connection, until their page arrives or they lapse.
    @ObservationIgnored private var startedSignIns: [UUID: Date] = [:]

    /// Asks the Hub to sign a connection in. The Hub answers by pushing `signInPage`, which
    /// `takeSignInPage` lets open once.
    public func signIn(connectionID: UUID, redirect: URL, now: Date = Date()) async throws {
        // Before asking: the page can arrive before the answer does.
        let earlier = startedSignIns[connectionID], deadline = now.addingTimeInterval(Self.signInWait)
        startedSignIns[connectionID] = deadline
        do {
            _ = try await request(.signIn(connectionID: connectionID, redirect: redirect))
        } catch {
            // A second tap refused as "already signing in" leaves the first one's page able to open.
            if startedSignIns[connectionID] == deadline { startedSignIns[connectionID] = earlier }
            throw error
        }
    }

    /// Whether to open a sign-in page the Hub pushed: only a web page, and only once for a sign-in
    /// this device started, so a Hub cannot open pages, apps or other links on its own.
    public func takeSignInPage(for connectionID: UUID, url: URL, now: Date = Date()) -> Bool {
        guard let deadline = startedSignIns.removeValue(forKey: connectionID), deadline > now else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased())
    }

    /// A one-time invitation for another device of this user, when the Hub lets them pair their own.
    public func invite() async throws -> LinkInvitation {
        guard case .invitation(let invitation) = try await request(.invite) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return invitation
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
        try await download(to: destination) { .download(conversationID: conversationID, attachmentID: attachment.id, offset: $0) }
    }

    /// Sends a file for the reply of a bot this device hosts, piece by piece.
    public func upload(_ file: URL, as attachment: LinkAttachment, toHosted conversationID: UUID) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = 0
        repeat {
            let data = try handle.read(upToCount: LinkProtocol.chunkSize) ?? Data()
            _ = try await request(.host(.upload(conversationID: conversationID, attachment: attachment, offset: offset, data: data)))
            offset += data.count
        } while offset < attachment.byteCount
    }

    /// Saves a file someone sent a bot this device hosts to `destination`.
    public func download(_ attachment: LinkAttachment, fromHosted conversationID: UUID, to destination: URL) async throws {
        try await download(to: destination) { .host(.download(conversationID: conversationID, attachmentID: attachment.id, offset: $0)) }
    }

    /// Sends a picture or video to be a conversation's background on the Hub, piece by piece.
    public func uploadBackground(_ file: URL, to conversationID: UUID) async throws -> LinkBackground {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let byteCount = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let upload = UUID()
        var offset = 0
        while true {
            let data = try handle.read(upToCount: LinkProtocol.chunkSize) ?? Data()
            let answer = try await request(.uploadBackground(LinkBackgroundPiece(
                conversationID: conversationID, upload: upload, filename: file.lastPathComponent, byteCount: byteCount,
                offset: offset, data: data)))
            offset += data.count
            if case .background(let background) = answer { return background }
            guard case .done = answer, offset < byteCount, !data.isEmpty else { throw LinkError("The Hub sent an unexpected answer.") }
        }
    }

    /// Saves a conversation's background file from the Hub to `destination`: as the Hub keeps it, or its small copy.
    public func downloadBackground(_ media: String, of conversationID: UUID, compact: Bool, to destination: URL) async throws {
        try await download(to: destination) {
            .backgroundMedia(LinkBackgroundFetch(conversationID: conversationID, media: media, compact: compact, offset: $0))
        }
    }

    private func download(to destination: URL, piece: (Int) -> LinkRequest) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset = 0
        while true {
            guard case .chunk(let data, let total) = try await request(piece(offset)) else {
                throw LinkError("The Hub sent an unexpected answer.")
            }
            try handle.write(contentsOf: data)
            offset += data.count
            if offset >= total || data.isEmpty { break }
        }
    }

    /// `items` with the pictures their list left out filled in from those this device keeps.
    public func keptPictures<Item: LinkPictured>(_ items: [Item]) -> [Item] {
        items.map { item in
            guard item.picture == nil, let digest = item.pictureDigest, LinkPicture.isDigest(digest) else { return item }
            var filled = item
            filled.picture = try? Data(contentsOf: picturesURL(Item.self).appendingPathComponent(digest))
            return filled
        }
    }

    /// Fetches the pictures `items`, a whole list, left out that this device does not keep yet,
    /// and forgets those it no longer shows. A picture that cannot be fetched is tried next time.
    public func fetchPictures<Item: LinkPictured>(_ items: [Item]) async {
        let folder = picturesURL(Item.self)
        let wanted = Set(items.compactMap(\.pictureDigest).filter(LinkPicture.isDigest))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !wanted.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        for item in items where item.picture == nil {
            guard let digest = item.pictureDigest, wanted.contains(digest),
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent(digest).path),
                  case .picture(let data?)? = try? await request(.picture(item.pictureOwner)),
                  LinkPicture.digest(data) == digest else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent(digest), options: .atomic)
        }
    }

    private func keep<Item: LinkPictured>(_ picture: Data, for item: Item) {
        let folder = picturesURL(Item.self)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? picture.write(to: folder.appendingPathComponent(LinkPicture.digest(picture)), options: .atomic)
    }

    private func picturesURL<Item: LinkPictured>(_: Item.Type) -> URL {
        directory.appendingPathComponent("Pictures", isDirectory: true).appendingPathComponent(Item.pictureFolder, isDirectory: true)
    }

    /// Opens the stream the joined Hub pushes events down.
    public func subscribe() async throws -> AsyncThrowingStream<LinkEvent, Error> {
        try await stream(.subscribe)
    }

    /// Opens a channel to the Hub for a request it answers with a stream, such as `openSurface`:
    /// frames come down it, and this side sends its own up it.
    public func channel(_ request: LinkRequest) async throws -> LinkChannel {
        guard let hub else { throw LinkError("This Mac has not joined a Noodle Hub.") }
        let channel = try await LinkClient.channel(try LinkProtocol.encode(request), identity: try identity(),
                                                   hubKey: hub.key, endpoints: hub.endpoints)
        return channel
    }

    /// Opens a stream for a request the Hub answers with a stream.
    public func stream(_ request: LinkRequest) async throws -> AsyncThrowingStream<LinkEvent, Error> {
        guard let hub else { throw LinkError("This Mac has not joined a Noodle Hub.") }
        let subscription = try await LinkClient.subscribe(try LinkProtocol.encode(request), identity: try identity(),
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

    private func exchange(_ request: LinkRequest, as identity: LinkIdentity, key: LinkPublicKey,
                          endpoints: [LinkEndpoint]) async throws -> LinkStatus {
        switch try await send(request, as: identity, key: key, endpoints: endpoints) {
        case .status(let status): return status
        case .failure(let message): throw LinkError(message)
        default: throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    private func send(_ request: LinkRequest, as identity: LinkIdentity, key: LinkPublicKey,
                      endpoints: [LinkEndpoint]) async throws -> LinkResponse {
        let (data, endpoint) = try await LinkClient.exchange(try LinkProtocol.encode(request), identity: identity,
                                                             hubKey: key, endpoints: endpoints)
        self.endpoint = endpoint
        let response = try LinkProtocol.decodeResponse(data)
        if case .failure(let message) = response { throw LinkError(message) }
        return response
    }

    private func identity() throws -> LinkIdentity {
        try LinkIdentity.loadOrCreate(at: directory.appendingPathComponent(Self.keyName))
    }

    private func save(_ hub: Hub) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(hub).write(to: hubURL, options: .atomic)
        self.hub = hub
    }

    private func remember(_ status: LinkStatus) {
        self.status = status
        avatar = keptAvatar
        try? LinkProtocol.encoder.encode(status).write(to: statusURL, options: .atomic)
    }

    private var hubURL: URL { directory.appendingPathComponent("hub.json") }
    private var statusURL: URL { directory.appendingPathComponent("status.json") }
    private var leavingURL: URL { directory.appendingPathComponent(Self.leavingName) }
    private static let keyName = "device.key"
    private static let leavingName = "leaving.json"
}

/// A noodlet a bot shared, opened to run on this device. The Hub forgets what it opened when it
/// restarts, so this opens it again when the Hub says so, and the person never sees it.
public actor LinkNoodletSession {
    public typealias Request = @Sendable (LinkRequest) async throws -> LinkResponse
    private let conversationID: UUID
    private let attachmentID: UUID
    private let request: Request
    public private(set) var noodlet: LinkNoodlet

    private init(conversationID: UUID, attachmentID: UUID, request: @escaping Request, noodlet: LinkNoodlet) {
        self.conversationID = conversationID
        self.attachmentID = attachmentID
        self.request = request
        self.noodlet = noodlet
    }

    public static func open(conversationID: UUID, attachmentID: UUID, request: @escaping Request) async throws -> LinkNoodletSession {
        LinkNoodletSession(conversationID: conversationID, attachmentID: attachmentID, request: request,
                           noodlet: try await ready(conversationID, attachmentID, request))
    }

    private static func ready(_ conversationID: UUID, _ attachmentID: UUID, _ request: Request) async throws -> LinkNoodlet {
        guard case .noodlet(let noodlet) = try await request(.noodlet(conversationID: conversationID, attachmentID: attachmentID))
        else { throw LinkError("The Hub sent an unexpected answer.") }
        return noodlet
    }

    /// Opens the noodlet again if `error` says the Hub forgot it: whether it did.
    public func renew(after error: Error) async throws -> Bool {
        guard (error as? LinkError)?.message == LinkProtocol.noodletForgotten else { return false }
        noodlet = try await Self.ready(conversationID, attachmentID, request)
        return true
    }

    /// A piece of the noodlet's files from `offset`, the same files even if the Hub forgot them.
    public func archive(from offset: Int) async throws -> Data {
        let revision = noodlet.revision
        do {
            return try await archivePiece(from: offset)
        } catch {
            guard try await renew(after: error), noodlet.revision == revision else { throw error }
            return try await archivePiece(from: offset)
        }
    }

    private func archivePiece(from offset: Int) async throws -> Data {
        guard case .chunk(let data, _) = try await request(.noodletArchive(grant: noodlet.grant, offset: offset))
        else { throw LinkError("The Hub sent an unexpected answer.") }
        return data
    }

    /// Sends a piece of the call `id` on the noodlet's data and secrets; the last one answers.
    public func call(id: UUID, offset: Int, total: Int, data: Data) async throws -> Data? {
        switch try await request(.noodletCall(LinkNoodletCall(grant: noodlet.grant, id: id, offset: offset, total: total, data: data))) {
        case .done: return nil
        case .noodletAnswer(let answer): return answer
        default: throw LinkError("The Hub sent an unexpected answer.")
        }
    }
}
