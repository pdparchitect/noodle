import AppletBridge
import Foundation
import HubWire
import NoodleRuntime

/// Noodlets its bots shared, run on a person's own device. The Hub hands out their files and
/// answers their pages' calls on data and secrets, which stay with Noodle Applet on this Mac.
/// Each opening gets a grant only its user's devices can use, for as long as they keep using it.
/// Applet is asked as the bot that shared the noodlet, so it too checks the noodlet is the bot's.
@MainActor final class HubNoodlets {
    private struct Grant {
        let user: UUID
        let noodlet: UUID
        /// The bot that shared it, as Applet knows it.
        let bot: String
        /// The conversation it was shared in, which the user must still be able to open.
        let conversation: UUID
        let archive: UUID
        /// The archive's size, as Applets from before it was packed in the background tell it.
        let byteCount: Int
        var used: Date
    }

    /// How long a grant lasts unused.
    static let lifetime: TimeInterval = 12 * 3600
    private let applets: any HubNoodletRunning
    private let now: () -> Date
    /// Whether a user can still open a conversation.
    private let canOpen: (_ conversation: UUID, _ user: UUID) -> Bool
    private var grants: [UUID: Grant] = [:]
    /// Calls arriving in pieces, by their id, until the last piece.
    private var pending: [UUID: (grant: UUID, data: Data, started: Date)] = [:]

    init(applets: any HubNoodletRunning, now: @escaping () -> Date, canOpen: @escaping (_ conversation: UUID, _ user: UUID) -> Bool) {
        self.applets = applets
        self.now = now
        self.canOpen = canOpen
    }

    /// Answered at once with the size of its files, or when `packed`, for a device from before
    /// that, once its archive is written, with the archive's size.
    func open(_ noodlet: UUID, of bot: UUID, in conversation: UUID, for user: UUID, packed: Bool = false) async throws -> LinkNoodlet {
        var request = AppletRequest(.archive)
        request.noodletID = noodlet
        request.owner = bot.uuidString.lowercased()
        let response = try await applets.companion(request)
        guard let archive = response.artifactID, let revision = response.revision, let byteCount = response.byteCount,
              let manifest = response.manifest else {
            throw LinkError("Update \(AppletBuildIdentity.current.appName) to open noodlets on your devices.")
        }
        var size = byteCount
        if packed {
            var read = AppletRequest(.artifact)
            read.artifactID = archive
            read.offset = 0
            read.owner = request.owner
            while true {
                let piece = try await applets.companion(read)
                if piece.data?.isEmpty == false || piece.done == true {
                    size = piece.byteCount ?? byteCount
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
        grants = grants.filter { now().timeIntervalSince($0.value.used) < Self.lifetime }
        let grant = UUID()
        grants[grant] = Grant(user: user, noodlet: noodlet, bot: bot.uuidString.lowercased(), conversation: conversation,
                              archive: archive, byteCount: byteCount, used: now())
        return LinkNoodlet(grant: grant, noodletID: noodlet, revision: revision, byteCount: size,
                           manifest: try JSONEncoder().encode(manifest))
    }

    /// A piece of the noodlet's archive from `offset`, and the archive's size; nothing and no size
    /// while Applet is still writing it.
    func archive(_ id: UUID, from offset: Int, for user: UUID) async throws -> (Data, Int) {
        let grant = try granted(id, to: user)
        var request = AppletRequest(.artifact)
        request.artifactID = grant.archive
        request.offset = offset
        request.owner = grant.bot
        let response = try await applets.companion(request)
        let data = response.data ?? Data()
        return (data, response.byteCount ?? (data.isEmpty ? 0 : grant.byteCount))
    }

    /// Takes a piece of a page's call, and once it has them all, what the noodlet answered.
    func call(_ piece: LinkNoodletCall, for user: UUID) async throws -> Data? {
        let grant = try granted(piece.grant, to: user)
        pending = pending.filter { now().timeIntervalSince($0.value.started) < 300 }
        var sofar = pending.removeValue(forKey: piece.id) ?? (piece.grant, Data(), now())
        guard sofar.grant == piece.grant, piece.offset == sofar.data.count, piece.total <= AppletConnection.maxFrame,
              piece.offset + piece.data.count <= piece.total else { throw LinkError("The noodlet's call arrived out of order.") }
        sofar.data.append(piece.data)
        guard sofar.data.count == piece.total else {
            pending[piece.id] = sofar
            return nil
        }
        var request = AppletRequest(.store)
        request.noodletID = grant.noodlet
        request.owner = grant.bot
        request.store = try JSONDecoder().decode(NoodletStoreCall.self, from: sofar.data)
        return try JSONEncoder().encode(try await applets.companion(request).stored ?? .null)
    }

    private func granted(_ id: UUID, to user: UUID) throws -> Grant {
        guard var grant = grants[id], grant.user == user, now().timeIntervalSince(grant.used) < Self.lifetime,
              canOpen(grant.conversation, user) else {
            throw LinkError(LinkProtocol.noodletForgotten)
        }
        grant.used = now()
        grants[id] = grant
        return grant
    }
}
