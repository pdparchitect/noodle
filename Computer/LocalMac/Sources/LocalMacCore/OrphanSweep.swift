import Foundation

/// Tracks background logins that no desktop helper is serving. The app normally
/// stops them, but a crash, force quit or quit that outlives its deadline never
/// sends Stop. The grace period leaves time for Start to adopt the same login.
public struct LocalMacOrphanSweep {
    public static let defaultGrace: TimeInterval = 300
    public let grace: TimeInterval
    private var since: [UUID: Date] = [:]
    public init(grace: TimeInterval = Self.defaultGrace) { self.grace = grace }

    /// Returns signed-in computers that had no attached desktop helper for the
    /// whole grace period. An attachment or logout restarts the clock.
    public mutating func expired(signedIn: Set<UUID>, attached: Set<UUID>, now: Date = Date()) -> Set<UUID> {
        let orphaned = signedIn.subtracting(attached)
        since = since.filter { orphaned.contains($0.key) }
        for id in orphaned where since[id] == nil { since[id] = now }
        return Set(since.filter { now.timeIntervalSince($0.value) >= grace }.keys)
    }
}
