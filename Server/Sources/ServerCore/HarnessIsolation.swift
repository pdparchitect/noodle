import Foundation
import NoodleCore

/// How this machine keeps a bot's harness to its own bot: bubblewrap on Linux, Seatbelt on a Mac, a restricted token
/// on Windows. The server
/// checks `problem()` before it starts, and launches each harness from the plan `launch` makes.
public protocol HarnessIsolation: Sendable {
    /// Why bots cannot be isolated here, or nil when they can.
    func problem() -> String?
    /// How to launch `program`, already resolved, with `command` for the bot at `workspace`, with `environment`
    /// as its whole environment.
    func launch(workspace: URL, program: URL, command: [String], environment: [String: String]) throws -> HarnessLaunchPlan
    /// What `provider`'s harness needs in its environment besides its command's, made ready for the bot at
    /// `workspace` once its login is.
    func environment(provider: HarnessProvider, workspace: URL) throws -> [String: String]
}

extension HarnessIsolation {
    public func environment(provider: HarnessProvider, workspace: URL) throws -> [String: String] { [:] }
}

/// What a launcher runs for a bot's harness: a program, its arguments and its whole environment, where it
/// starts, and how what it starts is ended.
public struct HarnessLaunchPlan: Equatable, Sendable {
    /// What the admin knows the program as, for when it cannot start.
    public var name: String
    public var executable: URL
    public var arguments: [String]
    /// Everything the program's environment holds; nothing of the server's own is passed on.
    public var environment: [String: String]
    /// Where it starts, or nil for where the server is.
    public var directory: URL?
    /// Whether stopping it signals its whole process group, and its exit ends what is left of the group: for an
    /// isolation that does not end a harness's tools with it, as bubblewrap does.
    public var endsGroup: Bool
    #if os(Windows)
    /// The name of the bot's own SID, which its sandbox is made with.
    public var sandbox: String?
    #endif

    public init(name: String, executable: URL, arguments: [String], environment: [String: String], directory: URL?,
                endsGroup: Bool) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
        self.endsGroup = endsGroup
    }
}

#if os(Linux)
public typealias PlatformHarnessIsolation = HarnessSandbox
#elseif os(macOS)
public typealias PlatformHarnessIsolation = SeatbeltSandbox
#elseif os(Windows)
public typealias PlatformHarnessIsolation = RestrictedTokenSandbox
#endif
