import Foundation

/// Durable wake intent, scoped to the same provider/access mode as its session.
/// Stopping or losing a process must not clear this marker. Only a terminal
/// turn result does; the agent decides how to safely resume unfinished work.
public struct AgentTurnRecovery {
    private let url: URL
    private var token: Data?

    public init(sessionStateURL: URL) {
        url = sessionStateURL.appendingPathExtension("unfinished")
    }

    public var hasUnfinishedTurn: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public mutating func begin() throws {
        let next = Data(UUID().uuidString.utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try next.write(to: url, options: .atomic)
        token = next
    }

    public mutating func finish() throws {
        guard let token else { return }
        // A late callback from an older runtime cannot erase a newer turn.
        do {
            if try Data(contentsOf: url) == token {
                try FileManager.default.removeItem(at: url)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Already cleared, e.g. by an explicit session reset.
        }
        self.token = nil
    }
}

/// Each harness and access mode keeps its own private session. A bot that runs on another one than last
/// time starts that one's session fresh, since an old one missed everything since, and its first turn
/// catches up from the conversation and workspace. The mark sits beside the session it applies to.
public struct HarnessHandoff {
    private let url: URL
    private let workspace: URL?

    public init(sessionStateURL: URL, workspace: URL? = nil) {
        url = sessionStateURL.appendingPathExtension("handoff")
        self.workspace = workspace
    }

    public var isPending: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// What a turn adds to its prompt: a replaced session's own history recovery, or else the handoff's catch-up.
    public func context(recoveringHistory: Bool = false) -> String {
        var context = ""
        if recoveringHistory { context = "\n\n" + MessengerDocumentation.recoveredModelContext }
        else if isPending { context = "\n\n" + MessengerDocumentation.harnessHandoffContext }
        guard let workspace,
              let layout = try? AgentStorageLayout.containing(workspace),
              let agentID = UUID(uuidString: layout.package.lastPathComponent) else { return context }
        let root = layout.package.deletingLastPathComponent().deletingLastPathComponent()
        if let away = try? WorkspaceRepository(rootURL: root).loadOwnerAway(forAgent: agentID), away.isActive() {
            context += "\n\n" + away.notice
        }
        return context
    }

    /// Once a turn carrying the catch-up has been sent.
    public func clear() { try? FileManager.default.removeItem(at: url) }

    /// Records `sessionState` as the session the bot runs on. If it last ran on another, this one's saved
    /// session is dropped, the handoff marked, and an unfinished turn carried over so it is not lost.
    public static func enter(_ sessionState: URL) throws {
        let files = FileManager.default
        let runtime = sessionState.deletingLastPathComponent(), name = sessionState.lastPathComponent
        let inUse = runtime.appendingPathComponent("session-in-use")
        let previous = (try? String(contentsOf: inUse, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard previous != name else { return }
        try files.createDirectory(at: runtime, withIntermediateDirectories: true)
        // Bots first started before this was recorded have no previous session to hand off from.
        if let previous, !previous.isEmpty, !previous.contains("/") {
            let unfinished = sessionState.appendingPathExtension("unfinished")
            let carried = runtime.appendingPathComponent(previous).appendingPathExtension("unfinished")
            for stale in [sessionState, unfinished] where files.fileExists(atPath: stale.path) { try files.removeItem(at: stale) }
            if files.fileExists(atPath: carried.path) { try files.moveItem(at: carried, to: unfinished) }
            try Data().write(to: HarnessHandoff(sessionStateURL: sessionState).url, options: .atomic)
        }
        try Data(name.utf8).write(to: inUse, options: .atomic)
    }
}
