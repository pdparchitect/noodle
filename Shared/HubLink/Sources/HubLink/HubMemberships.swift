import Foundation
import Observation

/// Every Hub this device joined, such as its own and a friend's. Each keeps its own folder
/// and key, so Hubs cannot tell they are talking to the same device.
@MainActor @Observable public final class HubMemberships {
    public private(set) var hubs: [HubPairing] = []
    public private(set) var isJoining = false
    public private(set) var joinError: String?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private var folders: [ObjectIdentifier: URL] = [:]

    public init(directory: URL, deviceName: String) {
        self.directory = directory
        self.deviceName = deviceName
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders.sorted(by: Self.created) {
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
            return
        }
        let existing = hubs.first { $0.hub?.key == invitation.hubKey }
        let folder = existing.flatMap { folders[ObjectIdentifier($0)] }
            ?? directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let pairing = existing ?? HubPairing(directory: folder, deviceName: deviceName)
        await pairing.join(invitationText)
        joinError = pairing.error
        guard existing == nil else { return }
        if pairing.hub == nil {
            try? FileManager.default.removeItem(at: folder)
        } else {
            hubs.append(pairing)
            folders[ObjectIdentifier(pairing)] = folder
        }
    }

    /// Forgets the Hub and this device's key for it.
    public func leave(_ pairing: HubPairing) {
        pairing.leave()
        if let folder = folders.removeValue(forKey: ObjectIdentifier(pairing)) {
            try? FileManager.default.removeItem(at: folder)
        }
        hubs.removeAll { $0 === pairing }
    }

    public func refreshAll() async {
        for pairing in hubs { await pairing.refresh() }
    }

    /// Checks in with every Hub until cancelled, which is how each knows this device is connected.
    public func stayConnected() async {
        while !Task.isCancelled {
            for pairing in hubs { await pairing.refresh(quietly: true) }
            try? await Task.sleep(for: HubPairing.checkInInterval)
        }
    }

    public func clearJoinError() { joinError = nil }

    private static func created(_ lhs: URL, _ rhs: URL) -> Bool {
        let date = { (url: URL) in (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return (date(lhs), lhs.lastPathComponent) < (date(rhs), rhs.lastPathComponent)
    }
}
