import Foundation

/// What a restricted bot's harness may reach, whatever keeps it there: Seatbelt on a Mac, bubblewrap on Linux, a
/// restricted token on Windows. Each renders the same policy in its own terms, so a harness, a shared folder or the
/// silo's egress is described once for every platform.
public struct HarnessSandboxPolicy: Equatable, Sendable {
    /// Read and written: the bot's workspace, which holds its private home and temporary files.
    public var workspace: URL
    /// Read and run, with everything below them: the bot's package, the app it runs with and the harness's code.
    public var readable: [String]
    /// Single files read where their folders are not, such as the folders above the workspace for a harness
    /// that walks to it from `/`.
    public var readableFiles: [String]
    /// The person's folders shared with the bot, each read and written or only read.
    public var folders: [AgentFolder]
    /// Where the harness's network may go: anywhere when nil, otherwise only the silo's proxy on this local port.
    public var egressPort: UInt16?
    /// The harness's own executable, which some allowances below are kept to, so the tools it runs never get them.
    public var executable: String?
    /// The executable may listen on this machine, as OpenCode's and Antigravity's own servers do.
    public var listensLocally: Bool
    /// The harness runs its commands in pseudo-terminals it opens itself, as Antigravity does.
    public var pseudoTerminals: Bool
    /// The executable checks certificates through macOS's Security service, as Copilot does.
    public var securityService: Bool

    public init(workspace: URL, readable: [String], readableFiles: [String] = [], folders: [AgentFolder] = [],
                egressPort: UInt16? = nil, executable: String? = nil, listensLocally: Bool = false,
                pseudoTerminals: Bool = false, securityService: Bool = false) {
        self.workspace = workspace
        self.readable = readable
        self.readableFiles = readableFiles
        self.folders = folders
        self.egressPort = egressPort
        self.executable = executable
        self.listensLocally = listensLocally
        self.pseudoTerminals = pseudoTerminals
        self.securityService = securityService
    }

    /// Everything written: the workspace and the shared folders that may be.
    public var writable: [String] { [workspace.path] + folders.filter(\.writable).map(\.path) }
}
