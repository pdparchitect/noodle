import Foundation

/// The console user macOS publishes in the dynamic store (State:/Users/ConsoleUser)
/// decides whose settings drive the shared hardware: bluetoothd only serves that
/// user's audioaccessoryd (AirPods), and Night Shift, True Tone, keyboard modifier
/// remapping, disk ownership, the camera, VPN tunnels and Continuity follow it. The
/// WindowServer's on-console session is a separate fact. loginwindow publishes every
/// GUI login, a background one included, and nothing publishes the person at the
/// screen again until they log in.
///
/// Only loginwindow and logind carry the entitlement configd requires for that key;
/// root is refused, and logind offers its setter only to loginwindow. loginwindow does
/// republish on its own when its configd connection drops, but only the one whose
/// session is on console, so restarting configd puts the person at the screen back.
public enum LocalMacConsoleUser {
    /// Whether the published console user must be put back. Only a managed account
    /// published while another session is on the console is; every other change belongs
    /// to loginwindow (a person's own login or fast user switch, or a managed account
    /// brought on console).
    public static func needsRepublish(published: UInt32?, sessions: [[String: Any]], managed: Set<UInt32>) -> Bool {
        guard let published, managed.contains(published),
              let active = sessions.first(where: { $0["kCGSSessionOnConsoleKey"] as? Bool == true }),
              let uid = (active["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value else { return false }
        return uid != published
    }
}

/// Spaces out configd restarts. Each one briefly interrupts networking, and the
/// service checks the console user repeatedly while a login settles.
public struct LocalMacConfigdRestart: Sendable {
    public static let interval: TimeInterval = 15
    private var last: Date?
    public init() {}

    /// Seconds to wait before the next restart may run; zero when it may run now.
    public func wait(now: Date) -> TimeInterval {
        guard let last else { return 0 }
        return max(0, Self.interval - now.timeIntervalSince(last))
    }
    public mutating func ran(at date: Date) { last = date }
}
