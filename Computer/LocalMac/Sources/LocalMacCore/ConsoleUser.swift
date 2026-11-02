import Foundation

/// The console user macOS publishes in the dynamic store (State:/Users/ConsoleUser)
/// decides whose settings drive the shared hardware: bluetoothd only serves that
/// user's audioaccessoryd (AirPods), and Night Shift, True Tone, keyboard modifier
/// remapping, disk ownership and Continuity follow it. The WindowServer's
/// on-console session is a separate fact. loginwindow publishes every GUI login,
/// a background one included, and nothing publishes the person at the screen
/// again until they log in, so the lifecycle service puts them back.
public struct LocalMacConsoleUser: Equatable, Sendable {
    public let name: String
    public let uid: UInt32
    public let gid: UInt32
    public init(name: String, uid: UInt32, gid: UInt32) { self.name = name; self.uid = uid; self.gid = gid }

    /// The user to publish in place of `published`, or nil when it needs no repair.
    /// Only a managed account published while another session is on the console is
    /// replaced; every other change belongs to loginwindow (a person's own login or
    /// fast user switch, or a managed account brought on console).
    public static func repair(published: UInt32?, sessions: [[String: Any]], managed: Set<UInt32>) -> LocalMacConsoleUser? {
        guard let published, managed.contains(published),
              let active = sessions.first(where: { $0["kCGSSessionOnConsoleKey"] as? Bool == true }),
              let uid = (active["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value, uid != published,
              let gid = (active["kCGSSessionGroupIDKey"] as? NSNumber)?.uint32Value,
              let name = active["kCGSSessionUserNameKey"] as? String, !name.isEmpty else { return nil }
        return LocalMacConsoleUser(name: name, uid: uid, gid: gid)
    }
}
