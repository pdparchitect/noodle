import Foundation
import Observation

/// Every Hub this device joined, such as its own and a friend's. Each keeps its own folder
/// and key, so Hubs cannot tell they are talking to the same device.
@MainActor @Observable public final class HubMemberships {
    public private(set) var hubs: [HubPairing] = []
    public private(set) var isJoining = false
    /// The invitation being joined, while it is.
    public private(set) var joining: LinkInvitation?
    public private(set) var joinError: String?
    /// The invitation of a join that reached no address of its Hub, for working out why.
    public private(set) var unreachableInvitation: LinkInvitation?
    /// An invitation from an opened link, waiting for the person to confirm it.
    public private(set) var offered: LinkInvitation?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var folders: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var joinTask: Task<Void, Never>?
    @ObservationIgnored private var joinCancelled = false
    /// Folders of Hubs this device left without telling them yet.
    @ObservationIgnored private var leaving: [URL] = []
    @ObservationIgnored private var sending: Task<Void, Never>?

    public init(directory: URL, deviceName: String) {
        self.directory = directory
        self.deviceName = deviceName
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders.sorted(by: Self.created) {
            if HubPairing.isLeaving(folder) {
                leaving.append(folder)
                continue
            }
            let pairing = HubPairing(directory: folder, deviceName: deviceName)
            guard pairing.hub != nil else { continue }
            hubs.append(pairing)
            self.folders[ObjectIdentifier(pairing)] = folder
        }
    }

    /// Joins the invitation's Hub; one already joined is joined again in place.
    public func join(_ invitationText: String) async {
        guard !isJoining else { return }
        isJoining = true
        defer { isJoining = false }
        let invitation: LinkInvitation
        do {
            invitation = try LinkInvitation(text: invitationText)
        } catch {
            joinError = error.localizedDescription
            unreachableInvitation = nil
            return
        }
        let existing = hubs.first { $0.hub?.key == invitation.hubKey }
        let folder = existing.flatMap { folders[ObjectIdentifier($0)] }
            ?? directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pairing = existing ?? HubPairing(directory: folder, deviceName: deviceName)
        joining = invitation
        defer { joining = nil }
        joinCancelled = false
        let task = Task { await pairing.join(invitationText) }
        joinTask = task
        await task.value
        joinTask = nil
        if joinCancelled {
            joinError = nil
            unreachableInvitation = nil
            if existing == nil, pairing.hub == nil { try? FileManager.default.removeItem(at: folder) }
            guard existing == nil, pairing.hub != nil else { return }
            hubs.append(pairing)
            folders[ObjectIdentifier(pairing)] = folder
            return
        }
        joinError = pairing.error
        unreachableInvitation = pairing.isUnreachable ? invitation : nil
        guard existing == nil else { return }
        if pairing.hub == nil {
            try? FileManager.default.removeItem(at: folder)
        } else {
            hubs.append(pairing)
            folders[ObjectIdentifier(pairing)] = folder
        }
    }

    /// Holds an opened link's invitation for the person to confirm, since any web page or app can open one.
    public func offer(_ invitationText: String) {
        do {
            offered = try LinkInvitation(text: invitationText)
            joinError = nil
            unreachableInvitation = nil
        } catch {
            offered = nil
            joinError = error.localizedDescription
            unreachableInvitation = nil
        }
    }

    public func declineOffered() { offered = nil }

    /// Leaves the Hub at once and tells it, now or, while it cannot be reached, at a later check-in.
    /// This device's key for it goes once the Hub has heard.
    public func leave(_ pairing: HubPairing) {
        pairing.leave()
        if let folder = folders.removeValue(forKey: ObjectIdentifier(pairing)) { leaving.append(folder) }
        hubs.removeAll { $0 === pairing }
        Task { await sendLeaves() }
    }

    public var hasUnsentLeaves: Bool { !leaving.isEmpty }

    /// Tells the Hubs this device left; those that cannot be reached are told next time.
    public func sendLeaves() async {
        if let sending { return await sending.value }
        let task = Task {
            for folder in leaving where await HubPairing.sendLeave(from: folder) {
                try? FileManager.default.removeItem(at: folder)
                leaving.removeAll { $0 == folder }
            }
        }
        sending = task
        await task.value
        sending = nil
    }

    public func refreshAll() async {
        await sendLeaves()
        for pairing in hubs { await pairing.refresh() }
    }

    /// Checks in with every Hub until cancelled, which is how each knows this device is connected.
    public func stayConnected() async {
        while !Task.isCancelled {
            await sendLeaves()
            for pairing in hubs { await pairing.refresh(quietly: true) }
            try? await Task.sleep(for: HubPairing.checkInInterval)
        }
    }

    /// Gives up on the join under way; it ends without a problem to show.
    public func cancelJoin() {
        joinCancelled = true
        joinTask?.cancel()
    }

    public func clearJoinError() {
        joinError = nil
        unreachableInvitation = nil
    }

    private static func created(_ lhs: URL, _ rhs: URL) -> Bool {
        let date = { (url: URL) in (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return (date(lhs), lhs.lastPathComponent) < (date(rhs), rhs.lastPathComponent)
    }
}
