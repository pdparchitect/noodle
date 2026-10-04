import AppletBridge
import BrowserBridge
import ComputerBridge
import Foundation
import HubLink
import Network
import NoodleCore
import NoodleRuntime
import Observation
import os

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
    /// The largest file, in bytes, a device may send to a conversation here.
    public var uploadLimit: Int {
        didSet { saveSettings() }
    }
    public static let defaultUploadLimit = 100_000_000
    /// The limits Settings offers, with the current one when it is none of them.
    public var uploadLimitChoices: [Int] {
        let choices = [25, 50, 100, 250, 500, 1_000, 2_000].map { $0 * 1_000_000 }
        return choices.contains(uploadLimit) ? choices : (choices + [uploadLimit]).sorted()
    }
    public private(set) var router = RouterState.off
    /// Bumped whenever an interface comes or goes or a Tailscale name turns up, so views reading the endpoints draw them again.
    private var networkChanges = 0
    public let key: LinkPublicKey
    /// What devices call this Hub: the owner's own name for it, or else the Mac's.
    public var hubName: String { customName.isEmpty ? macName : customName }
    /// The Mac's name, which the Hub goes by until the owner names it.
    public let macName: String
    /// The owner's name for this Hub; empty goes back to the Mac's. Devices take it up when they next check in.
    public var customName: String {
        didSet {
            let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != customName { customName = trimmed } else { saveSettings() }
        }
    }

    @ObservationIgnored private let identity: LinkIdentity
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let access: HubAccess
    @ObservationIgnored private let profiles: HarnessProfilesController
    @ObservationIgnored private let bots: HubBots?
    @ObservationIgnored private let connections: HubConnections?
    @ObservationIgnored private let computers: HubComputers?
    @ObservationIgnored private let browsers: HubBrowsers?
    @ObservationIgnored private let noodlets: HubNoodlets?
    /// Open event streams, by the key of the device holding each.
    @ObservationIgnored private var streams: [ObjectIdentifier: LinkStream] = [:]
    @ObservationIgnored private let port: UInt16
    @ObservationIgnored private let localEndpoints: (UInt16) -> [LinkEndpoint]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var server: LinkServer?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let routerMapper: (any RouterPortMapper)?
    /// Keeps the router's port open until cancelled.
    @ObservationIgnored private var routerRenewal: Task<Void, Never>?
    /// Unused invitations by their key. Kept in memory: an invitation outlives no relaunch.
    @ObservationIgnored private var invitations: [LinkPublicKey: (user: UUID, expires: Date, issuer: String)] = [:]
    @ObservationIgnored private let gate = LinkGate()
    /// Tells devices that are away about unread replies.
    @ObservationIgnored private let pushes: (any HubPushPublisher)?
    /// How long a conversation stays quiet before its devices are told, so a burst of replies is one push.
    @ObservationIgnored private let pushDelay: Duration
    /// Each conversation's unread replies, as last pushed or as first seen.
    @ObservationIgnored private var pushedUnread: [UUID: Int] = [:]
    @ObservationIgnored private var pendingPushes: [UUID: Task<Void, Never>] = [:]
    /// Live views open on each conversation, and whose they are, to close when someone loses it.
    @ObservationIgnored private var surfaces: [UUID: [(user: UUID, stream: LinkStream)]] = [:]

    private struct Settings: Codable {
        var manualAddress: String
        var opensRouterPort: Bool?
        var uploadLimit: Int?
        var name: String?
    }

    public init(hubName: String, directory: URL, access: HubAccess, profiles: HarnessProfilesController,
                bots: HubBots? = nil, connections: HubConnections? = nil, computers: HubComputers? = nil,
                browsers: HubBrowsers? = nil,
                port: UInt16 = LinkEndpoint.defaultPort, router: (any RouterPortMapper)? = nil,
                localEndpoints: @escaping (UInt16) -> [LinkEndpoint] = LinkEndpoint.local(port:),
                now: @escaping () -> Date = Date.init, pushes: (any HubPushPublisher)? = nil, pushDelay: Duration = .seconds(2)) {
        macName = hubName
        self.directory = directory
        self.access = access
        self.profiles = profiles
        self.bots = bots
        self.connections = connections
        self.computers = computers
        self.browsers = browsers
        noodlets = bots.map { bots in
            HubNoodlets(applets: bots.applets, now: now, canOpen: { [weak bots] in bots?.canOpen($0, for: $1) ?? false })
        }
        self.port = port
        routerMapper = router
        self.localEndpoints = localEndpoints
        self.now = now
        self.pushes = pushes
        self.pushDelay = pushDelay
        if pushes == nil { Self.pushLog.notice("Devices away are not notified: this build is not signed for iCloud") }
        // A Hub that cannot keep its key cannot be paired with; a fresh key each launch would say so loudly.
        identity = (try? LinkIdentity.loadOrCreate(at: directory.appendingPathComponent("hub.key"))) ?? LinkIdentity()
        key = identity.publicKey
        let settings = try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: directory.appendingPathComponent("link.json")))
        manualAddress = settings?.manualAddress ?? ""
        opensRouterPort = settings?.opensRouterPort ?? true
        uploadLimit = settings?.uploadLimit ?? Self.defaultUploadLimit
        customName = settings?.name ?? ""
        bots?.onChange = { [weak self] user, event in
            self?.push(event, to: user)
            self?.schedulePushes(for: event, of: user)
        }
        bots?.onClosed = { [weak self] conversation, user in self?.close(conversation, for: user) }
        connections?.onSignInEnded = { [weak self] user in self?.push(.connectionsChanged, to: user) }
        updateGate()
        watchDevices()
        usersSeen = UsersSeen(access)
        watchUsers()
        NotificationCenter.default.addObserver(forName: LinkEndpoint.localNamesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
    }

    public func start() async {
        guard server == nil else { return }
        state = .starting
        do {
            let server = try LinkServer(identity: identity, port: port, admits: gate.admits) { [weak self] key, request in
                await self?.reply(to: request, from: key) ?? .response(Data())
            }
            try await server.start()
            self.server = server
            state = .listening(port: server.port ?? port)
            watchNetwork()
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
        pathMonitor?.cancel()
        pathMonitor = nil
        state = .stopped
    }

    /// What invitations and paired devices are told to try, in order.
    public var endpoints: [LinkEndpoint] {
        _ = networkChanges
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
        // Only the invitation carries the private half; the Hub keeps the public one to let it in.
        let join = LinkIdentity()
        let expires = now().addingTimeInterval(LinkInvitation.lifetime)
        invitations[join.publicKey] = (user.id, expires, access.actor.who)
        access.note("Invited a device for \(user.name)", about: [user.id])
        updateGate()
        return LinkInvitation(hubName: hubName, hubKey: key, endpoints: endpoints, userName: user.name,
                              joinKey: join.privateKey.rawRepresentation, expires: expires)
    }

    func reply(to data: Data, from key: LinkPublicKey) async -> LinkReply {
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
        if case .openSurface(let conversationID, let attachmentID) = request {
            do {
                let user = try user(key)
                if access.isPersonal { try readNoodlesTools() }
                let (link, bot) = try await hubBots().companionLink(attachmentID, in: conversationID, for: user)
                // Starting a computer or a noodlet can outlast a request, so the channel opens first
                // and anything that then goes wrong comes down it.
                let open: @MainActor () async throws -> (SurfaceSocket, Gamepad?)
                switch link {
                case .browser(let browser, let tab):
                    // Every browser on the owner's own Mac is theirs.
                    guard let tab, try access.isPersonal || hubBrowsers().browsers(for: user).contains(where: { $0.id == browser }) else {
                        throw LinkError("That browser is not yours or no longer exists.")
                    }
                    let browsers = try hubBrowsers()
                    open = { (try await browsers.openSurface(browser: browser, tab: tab, for: user), nil) }
                case .computer(let computer, let terminal, _):
                    guard try access.isPersonal || hubComputers().computers(for: user).contains(where: { $0.id == computer }) else {
                        throw LinkError("That computer is not yours or no longer exists.")
                    }
                    let computers = try hubComputers()
                    open = { (try await computers.openSurface(computer: computer, terminal: terminal, bot: bot, for: user), nil) }
                case .noodlet(let noodlet):
                    // Asked for the bot that shared it, Applet checks it is the bot's as it starts it.
                    let applets = try hubBots().applets, owner = bot.uuidString.lowercased()
                    var info = AppletRequest(.info)
                    info.noodletID = noodlet
                    info.owner = owner
                    guard try await applets.companion(info).permissions?.isEmpty != false else {
                        throw LinkError("This noodlet uses the camera, microphone or screen, so it runs on your device. Update Noodle to open it.")
                    }
                    open = {
                        var start = AppletRequest(.open)
                        start.noodletID = noodlet
                        start.owner = owner
                        start.mode = "background"
                        let started = try await applets.companion(start)
                        guard let session = started.sessionID else {
                            throw LinkError("Noodle Applet did not start the noodlet.")
                        }
                        return (try await applets.companionSurface(AppletRequest(.surfaceStream, sessionID: session)), started.controls)
                    }
                }
                return .stream { stream in
                    Task { @MainActor in
                        self.surfaces[conversationID, default: []].removeAll { $0.stream.isClosed }
                        self.surfaces[conversationID, default: []].append((user.id, stream))
                        stream.send(LinkProtocol.encode(LinkEvent.surfaceOpened(sessionID: UUID())))
                        do {
                            let (socket, controls) = try await open()
                            if let controls { stream.send(LinkProtocol.encode(LinkEvent.surfaceControls(controls: controls))) }
                            LinkSurface.relay(socket, to: stream)
                        }
                        catch {
                            stream.send(LinkProtocol.encode(LinkEvent.surfaceFailed(reason: error.localizedDescription)))
                            stream.close()
                        }
                    }
                }
            } catch {
                return .response(LinkProtocol.encode(LinkResponse.failure(error.localizedDescription)))
            }
        }
        var response: LinkResponse
        do {
            response = try await handle(request, from: key)
            // Lists stay small however many pictures they show; the device fetches each once.
            if LinkProtocol.fetchesPictures(data) {
                switch response {
                case .bots(let bots): response = .bots(bots.map(\.withoutPicture))
                case .connections(let connections): response = .connections(connections.map(\.withoutPicture))
                case .computers(let computers): response = .computers(computers.map(\.withoutPicture))
                case .browsers(let browsers): response = .browsers(browsers.map(\.withoutPicture))
                default: break
                }
            }
        } catch {
            response = .failure(error.localizedDescription)
        }
        return .response(LinkProtocol.encode(response))
    }

    /// Keeps the gate in step with the devices however they change, including from Settings.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    func networkChanged() {
        networkChanges += 1
    }

    /// What admins see of the users, without the check-ins that change it every minute.
    private struct UsersSeen: Equatable {
        var users: [HubUser]
        var devices: [UUID]
        var plans: [LinkPlanChoice]

        @MainActor init(_ access: HubAccess) {
            users = access.users
            devices = access.devices.map(\.id)
            plans = access.plans.map { LinkPlanChoice(id: $0.id, name: $0.name) }
        }
    }
    @ObservationIgnored private var usersSeen: UsersSeen?

    /// Tells admins' devices when the users change, however they change, including on the Hub.
    private func watchUsers() {
        withObservationTracking { _ = (access.users, access.devices, access.plans) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let seen = UsersSeen(self.access)
                if seen != self.usersSeen {
                    self.usersSeen = seen
                    for admin in self.access.users where admin.isAdmin { self.push(.usersChanged, to: admin.id) }
                }
                self.watchUsers()
            }
        }
    }

    private func watchDevices() {
        withObservationTracking { _ = access.devices } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateGate()
                self?.watchDevices()
            }
        }
    }

    /// Lets in paired devices and the keys of open invitations; drops whoever that no longer covers.
    private func updateGate() {
        invitations = invitations.filter { $0.value.expires > now() }
        gate.update(keys: Set(access.devices.map(\.key)), invitations: invitations.mapValues(\.expires))
        server?.disconnectRefused()
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

    /// Whether a device is following the Hub right now, and so shows replies itself.
    private func isFollowing(_ device: HubDevice) -> Bool {
        streams.values.contains { $0.peer == device.key && !$0.isClosed }
    }

    private func schedulePushes(for event: LinkEvent, of user: UUID) {
        guard pushes != nil else { return }
        let conversation: UUID, read: Bool
        switch event {
        case .conversationChanged(let id, _): (conversation, read) = (id, false)
        case .readChanged(let id, _): (conversation, read) = (id, true)
        default: return
        }
        // What waits unread when the Hub first sees a conversation is not news, however soon a reply follows.
        if pushedUnread[conversation] == nil, !read {
            pushedUnread[conversation] = (try? bots?.unread(in: conversation)) ?? 0
            return
        }
        pendingPushes[conversation]?.cancel()
        pendingPushes[conversation] = Task { [weak self, pushDelay] in
            try? await Task.sleep(for: pushDelay)
            guard !Task.isCancelled else { return }
            await self?.updatePushes(conversation, of: user, read: read)
        }
    }

    /// Tells the user's devices that are away how many replies wait unread, once more have come,
    /// and takes it back once they are read.
    private func updatePushes(_ conversation: UUID, of user: UUID, read: Bool) async {
        pendingPushes[conversation] = nil
        guard let pushes, let unread = try? bots?.unread(in: conversation) else { return }
        let known = pushedUnread[conversation]
        pushedUnread[conversation] = unread
        let devices = access.devices.filter { $0.user == user && $0.pushTopic != nil }
        if unread == 0, read || (known ?? 0) > 0 {
            for device in devices {
                do { try await pushes.withdraw(topic: device.pushTopic!, conversation: conversation) }
                catch { Self.pushLog.error("Could not take back a notification: \(error.localizedDescription, privacy: .public)") }
            }
        } else if let known, unread > known {
            let away = devices.filter { !isFollowing($0) }
            Self.pushLog.notice("\(unread, privacy: .public) unread: notifying \(away.count, privacy: .public) of \(devices.count, privacy: .public) devices that asked, the rest are connected")
            for device in away {
                do { try await pushes.publish(topic: device.pushTopic!, conversation: conversation, unread: unread) }
                catch { Self.pushLog.error("Could not notify a device: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// Someone can no longer open a conversation: what they watch of it live closes, and their
    /// devices away stop showing its unread replies.
    private func close(_ conversation: UUID, for user: UUID) {
        let open = surfaces[conversation] ?? []
        open.filter { $0.user == user }.forEach { $0.stream.close() }
        surfaces[conversation] = open.filter { $0.user != user && !$0.stream.isClosed }
        pendingPushes.removeValue(forKey: conversation)?.cancel()
        pushedUnread[conversation] = nil
        guard let pushes else { return }
        let devices = access.devices.filter { $0.user == user && $0.pushTopic != nil }
        Task {
            for device in devices {
                do { try await pushes.withdraw(topic: device.pushTopic!, conversation: conversation) }
                catch { Self.pushLog.error("Could not take back a notification: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    /// What happens to notifications for devices away, without topics, names or messages.
    private static let pushLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HubCore", category: "Notifications")

    private func checkUploadSize(_ byteCount: Int) throws {
        guard byteCount <= uploadLimit else {
            throw LinkError("\(hubName) takes files up to \(ByteCountFormatter.string(fromByteCount: Int64(uploadLimit), countStyle: .file)).")
        }
    }

    private func handle(_ request: LinkRequest, from key: LinkPublicKey) async throws -> LinkResponse {
        // On the owner's own Mac these are Noodle's, which changes them too: read them as it left them.
        if access.isPersonal {
            switch request {
            case .connections, .saveConnection, .deleteConnection, .assignConnections, .signIn, .finishSignIn, .picture,
                 .computers, .createComputer, .updateComputer, .deleteComputer, .assignComputers,
                 .browsers, .createBrowser, .updateBrowser, .deleteBrowser, .assignBrowsers:
                try readNoodlesTools()
            default: break
            }
        }
        switch request {
        case .enroll(let deviceKey, let proof, let deviceName):
            // The invitation's key arrives only from whoever holds the invitation, and works once.
            defer { updateGate() }
            let invitation = invitations.removeValue(forKey: key)
            let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "Device" : String(trimmed.prefix(80))
            let actor = HubActor(who: invitation.map { "Invitation from \($0.issuer)" } ?? "An invitation no longer valid", user: nil)
            return try access.acting(as: actor) {
                do {
                    guard let invitation, invitation.expires > now(),
                          let user = access.users.first(where: { $0.id == invitation.user }) else {
                        throw LinkError("This invitation is no longer valid. Ask for a new one.")
                    }
                    guard deviceKey.isJoinProof(proof, for: key) else { throw LinkError("This device could not prove its key.") }
                    return .status(status(for: access.addDevice(named: name, key: deviceKey, for: user, at: now())))
                } catch {
                    access.note("Tried to pair “\(name)”", refusal: error.localizedDescription, about: invitation.map { [$0.user] } ?? [])
                    throw error
                }
            }
        case .status:
            let device = try paired(key)
            access.markSeen(device, at: now())
            return .status(status(for: device))
        case .invite:
            return try logged(request, from: key) {
                let user = try user(key)
                guard user.canPairDevices else { throw LinkError("You cannot pair devices with \(hubName). Ask whoever keeps it.") }
                return .invitation(invite(user))
            }
        case .users:
            return try logged(request, from: key) { .users(try admin(key).users()) }
        case .addUser(let draft):
            return try logged(request, from: key) { .user(try admin(key).addUser(draft)) }
        case .updateUser(let id, let draft):
            return try logged(request, from: key) { .user(try admin(key).updateUser(id, with: draft)) }
        case .removeUser(let id):
            return try logged(request, from: key) {
                remove(try admin(key).managedUser(id))
                return .done
            }
        case .removeDevice(let id):
            return try logged(request, from: key) {
                access.remove(try admin(key).managedDevice(id))
                return .done
            }
        case .leave:
            return try logged(request, from: key) {
                access.remove(try paired(key))
                return .done
            }
        case .inviteUser(let id):
            return try logged(request, from: key) { .invitation(invite(try admin(key).managedUser(id))) }
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
        case .people:
            return .people(try hubBots().people(for: try user(key)))
        case .shareBot(let id, let people):
            return try logged(request, from: key) { .bot(try hubBots().share(id, with: people, for: try user(key))) }
        case .groups:
            return .groups(try hubBots().groups(for: try user(key)))
        case .createGroup(let draft):
            return .group(try hubBots().createGroup(draft, for: try user(key)))
        case .updateGroup(let id, let draft):
            return .group(try hubBots().updateGroup(id, with: draft, for: try user(key)))
        case .deleteGroup(let id):
            try hubBots().deleteGroup(id, for: try user(key))
            return .done
        case .archive(let change):
            try hubBots().setArchived(change.archived, id: change.id, for: try user(key))
            return .done
        case .kick(let botID):
            return try hubBots().kick(botID, for: try user(key)).map(LinkResponse.kickConfirmation) ?? .done
        case .confirmKick(let botID, let confirmationID):
            try hubBots().confirmKick(botID, confirmation: confirmationID, for: try user(key))
            return .done
        case .newSession(let botID):
            try hubBots().startNewSession(botID, for: try user(key))
            return .done
        case .messages(let conversationID, let after):
            return .messages(try hubBots().messages(in: conversationID, after: after, for: try user(key)))
        case .messagePage(let page):
            return .messages(try hubBots().page(page, for: try user(key)))
        case .send(let message):
            return .message(try hubBots().send(message.body, id: message.id, attachmentIDs: message.attachmentIDs,
                                               in: message.conversationID, for: try user(key)))
        case .upload(let conversationID, let attachment, let offset, let data):
            // Refused at the first piece, before any of the file is kept.
            try checkUploadSize(attachment.byteCount)
            try hubBots().receive(data, at: offset, of: attachment, in: conversationID, for: try user(key))
            return .done
        case .setBackground(let choice):
            return .background(try hubBots().setBackground(choice, for: try user(key)))
        case .uploadBackground(let piece):
            try checkUploadSize(piece.byteCount)
            return try await hubBots().receiveBackground(piece, for: try user(key)).map(LinkResponse.background) ?? .done
        case .backgroundMedia(let fetch):
            let (data, total) = try await hubBots().backgroundChunk(fetch, for: try user(key))
            return .chunk(data: data, total: total)
        case .linkCard(let conversationID, let attachmentID):
            return .linkCard(try await hubBots().card(of: attachmentID, in: conversationID, for: try user(key)))
        case .linkPreview(let conversationID, let attachmentID):
            return .picture(try await hubBots().picture(of: attachmentID, in: conversationID, for: try user(key)))
        case .download(let conversationID, let attachmentID, let offset):
            let (data, total) = try hubBots().chunk(of: attachmentID, in: conversationID, at: offset, for: try user(key))
            return .chunk(data: data, total: total)
        case .react(let change):
            return .message(try hubBots().react(change, for: try user(key)))
        case .markRead(let mark):
            try hubBots().markRead(mark, for: try user(key))
            return .done
        case .pushTopic(let registration):
            let topic = registration.topic.flatMap { (1...128).contains($0.count) ? $0 : nil }
            access.setPushTopic(topic, for: try paired(key))
            Self.pushLog.notice("A device \(topic == nil ? "stopped listening" : "listens", privacy: .public) for unread replies")
            return .done
        case .toolCatalog:
            _ = try user(key)
            return .toolCatalog(HubConnections.catalogue)
        case .connections:
            return .connections(try hubConnections().link(for: try user(key)))
        case .picture(let owner):
            let user = try user(key)
            switch owner {
            case .bot(let id): return .picture(try hubBots().picture(ofBot: id, for: user))
            case .connection(let id): return .picture(try hubConnections().link(for: user).first { $0.id == id }?.iconData)
            case .computer(let id): return .picture(try hubComputers().link(for: user).first { $0.id == id }?.icon)
            case .browser(let id): return .picture(try hubBrowsers().link(for: user).first { $0.id == id }?.icon)
            }
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
        case .openSurface:
            throw LinkError("Surfaces open a stream.")
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
        case .noodlet(let conversationID, let attachmentID):
            let user = try user(key)
            // The same rule as watching it live: a noodlet from the folder of the bot that shared it.
            guard case (.noodlet(let noodlet), let bot) = try await hubBots().companionLink(attachmentID, in: conversationID, for: user) else {
                throw LinkError("That is not a noodlet.")
            }
            return .noodlet(try await hubNoodlets().open(noodlet, of: bot, in: conversationID, for: user.id))
        case .noodletArchive(let grant, let offset):
            let (data, total) = try await hubNoodlets().archive(grant, from: offset, for: try user(key).id)
            return .chunk(data: data, total: total)
        case .noodletCall(let piece):
            return try await hubNoodlets().call(piece, for: try user(key).id).map(LinkResponse.noodletAnswer) ?? .done
        }
    }

    private func hubNoodlets() throws -> HubNoodlets {
        guard let noodlets else { throw LinkError("This Noodle Hub does not keep bots.") }
        return noodlets
    }

    /// Fails the request when they cannot be read: working on an older copy would save it over Noodle's.
    private func readNoodlesTools() throws {
        do {
            try connections?.reloadAssignments()
            try computers?.reloadAssignments()
            try browsers?.reloadAssignments()
        } catch { throw LinkError("Could not read this Mac's tools, computers and browsers.") }
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

    /// Makes the request's changes as the device's user, and keeps it in the log if the Hub refuses it.
    private func logged(_ request: LinkRequest, from key: LinkPublicKey, _ body: () throws -> LinkResponse) throws -> LinkResponse {
        let device = access.device(for: key), user = device.flatMap(access.user(for:))
        let actor = HubActor(who: device.map { "\(user?.name ?? "Someone") on \($0.name)" } ?? "A device not paired", user: user?.id)
        return try access.acting(as: actor) {
            do {
                return try body()
            } catch {
                let (what, users) = attempt(request, by: user)
                access.note(what, refusal: error.localizedDescription, about: users)
                throw error
            }
        }
    }

    /// What a refused request tried, and whom it was about.
    private func attempt(_ request: LinkRequest, by actor: HubUser?) -> (String, [UUID]) {
        func name(_ id: UUID) -> String { access.users.first { $0.id == id }?.name ?? "someone no longer on the Hub" }
        switch request {
        case .users:
            return ("Tried to list the users", [])
        case .addUser(let draft):
            let name = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ConversationName.maximumLength) ?? ""
            return (name.isEmpty ? "Tried to add someone" : "Tried to add \(name)", [])
        case .updateUser(let id, _):
            return ("Tried to change \(name(id))", [id])
        case .removeUser(let id):
            return ("Tried to remove \(name(id))", [id])
        case .removeDevice(let id):
            guard let device = access.devices.first(where: { $0.id == id }) else { return ("Tried to unpair a device no longer paired", []) }
            return ("Tried to unpair “\(device.name)”", [device.user])
        case .inviteUser(let id):
            return ("Tried to invite a device for \(name(id))", [id])
        case .leave:
            return ("Tried to leave", [])
        case .shareBot(let id, _):
            return ("Tried to change whom \(bots?.name(ofBot: id) ?? "a bot") is shared with", [])
        default:
            return (actor.map { "Tried to invite a device for \($0.name)" } ?? "Tried to invite a device", [])
        }
    }

    private func admin(_ key: LinkPublicKey) throws -> HubAdmin {
        try HubAdmin(try user(key), access: access, isConnected: isConnected)
    }

    /// Removes a user with their devices and everything they keep on the Hub.
    public func remove(_ user: HubUser) {
        bots?.removeBots(of: user)
        connections?.removeConnections(of: user)
        computers?.removeComputers(of: user)
        browsers?.removeBrowsers(of: user)
        access.remove(user)
    }

    private func hubBots() throws -> HubBots {
        guard let bots else { throw LinkError("This Noodle Hub does not keep bots.") }
        return bots
    }

    private func status(for device: HubDevice) -> LinkStatus {
        let user = access.users.first { $0.id == device.user }
        let plan = access.plans.first { $0.id == user?.plan }
        let lent: [HubHarness]
        if access.isPersonal, let bots {
            // What the Mac's bot editor offers: each installed harness, with or without one of its profiles.
            lent = bots.installedProviders.flatMap { provider in
                [HubHarness(provider: provider, profile: nil)]
                    + profiles.profiles(for: provider).map { HubHarness(provider: provider, profile: $0.id) }
            }
        } else {
            lent = Array(plan?.harnesses ?? [])
        }
        let harnesses = lent.compactMap { harness -> LinkHarness? in
            var profileName: String?
            if let id = harness.profile {
                // A profile deleted outside the plan editor lends nothing.
                guard let profile = profiles.profile(id) else { return nil }
                profileName = profile.displayName
            }
            let known = bots?.models(for: harness.provider) ?? []
            var models = known.map {
                LinkModel(id: $0.id, name: $0.displayName,
                          efforts: $0.supportedEfforts.map { LinkEffort(id: $0.id, name: $0.displayName) },
                          defaultEffort: $0.defaultEffort.isEmpty ? nil : $0.defaultEffort)
            }
            let allowed = user.flatMap { access.models(on: harness, for: $0) }
            if let allowed {
                // Models the Hub no longer lists stay usable until the plan drops them.
                models = models.filter { allowed.contains($0.id) }
                    + allowed.subtracting(known.map(\.id)).sorted().map { LinkModel(id: $0, name: $0) }
            }
            return LinkHarness(provider: harness.provider.rawValue, providerName: harness.provider.displayName,
                               profile: harness.profile, profileName: profileName, models: models,
                               restrictsModels: allowed != nil)
        }
        .sorted { ($0.providerName, $0.profileName ?? "") < ($1.providerName, $1.profileName ?? "") }
        return LinkStatus(hubName: hubName, userName: user?.name ?? "", planName: plan?.name ?? "",
                          harnesses: harnesses, endpoints: endpoints, canPairDevices: user?.canPairDevices ?? false,
                          isAdmin: !access.isPersonal && user?.isAdmin == true, canShareBots: !access.isPersonal && bots != nil)
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
        try? JSONEncoder().encode(Settings(manualAddress: manualAddress, opensRouterPort: opensRouterPort,
                                                  uploadLimit: uploadLimit, name: customName)).write(to: directory.appendingPathComponent("link.json"), options: .atomic)
    }
}

/// Who may finish a handshake, read on the link's queue while the devices change on the main actor.
private final class LinkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<LinkPublicKey> = []
    private var invitations: [LinkPublicKey: Date] = [:]

    func update(keys: Set<LinkPublicKey>, invitations: [LinkPublicKey: Date]) {
        lock.withLock {
            self.keys = keys
            self.invitations = invitations
        }
    }

    @Sendable func admits(_ key: LinkPublicKey) -> Bool {
        lock.withLock { keys.contains(key) || invitations[key].map { $0 > Date() } ?? false }
    }
}

/// Shows a device that is away how many replies wait unread in a conversation, as a notification.
/// Only the topic the device gave and the count leave the Hub; the device fetches the rest itself.
public protocol HubPushPublisher: Sendable {
    func publish(topic: String, conversation: UUID, unread: Int) async throws
    /// The replies were read: nothing more to show.
    func withdraw(topic: String, conversation: UUID) async throws
}
