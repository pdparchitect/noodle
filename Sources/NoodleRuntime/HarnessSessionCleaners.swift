import Foundation
import NoodleCore

/// What a harness's cleanup gets for one bot. The harness decides from it how its own sessions go.
@MainActor public struct HarnessSessionCleanupContext {
    public let agentID: UUID
    public let workspace: URL
    public let cutoff: Date
    /// The sessions the bot's runtime pointers name, lowercased; see `HarnessSessionCleanup.keptSessions`.
    public let kept: Set<String>
    /// Whether the bot runs its harness with unrestricted access, which keeps sessions in the person's own home.
    public let extendedAccess: Bool
    /// The bot's running harness process now, if any.
    public let process: @MainActor () -> (any AgentRuntimeProcess)?
    /// Where a harness is installed, when it is and is turned on.
    public let executable: @MainActor (HarnessProvider) -> URL?
    /// A connection to start a harness for this bot outside its runtime.
    public let connect: @MainActor () throws -> any HarnessRuntimeConnection
    /// Runs `work` while the bot cannot start: a start would stop a harness run for the bot outside its runtime,
    /// and must not race files being removed. Answers false, without running it, when the bot is running.
    public let whileStopped: @MainActor (@MainActor () async -> Void) async -> Bool
}

public enum SessionCleanupOutcome: Sendable { case done, busy }

/// One harness's way of deleting the sessions it kept in a bot's home.
@MainActor protocol HarnessSessionCleaner {
    var provider: HarnessProvider { get }
    /// Whether the bot's home holds this harness's sessions, whatever harness the bot uses now.
    func isPresent(in workspace: URL) -> Bool
    func cleanUp(_ context: HarnessSessionCleanupContext) async -> SessionCleanupOutcome
}

@MainActor enum HarnessSessionCleaners {
    // TODO: Copilot keeps its sessions under `.copilot` (`chats/<id>` in a person's own home) and lists them over ACP
    // without deleting; check its layout in a bot's home, and whether it copes with a folder removed, before a sweep.
    // TODO: Antigravity keeps `conversations` beside a `conversation_summaries.db` index and a `brain` folder under
    // `.gemini/antigravity-cli`, and lists over ACP without deleting; removing files would leave its index stale, so
    // check how it copes, with a bot on it, before a sweep.
    // TODO: Muse keeps a `session-index.db` under `.local/share/muse`, with no delete command or ACP; find where its
    // sessions live and how its index copes, with a bot on it, before a sweep.
    static let all: [any HarnessSessionCleaner] = [
        CodexSessionCleaner(), ACPSessionCleaner(provider: .openCode, folder: ".local/share/opencode"),
        ACPSessionCleaner(provider: .devin, folder: ".local/share/devin"), ClaudeSessionCleaner(), GrokSessionCleaner(),
        FXSessionCleaner()
    ]

    static func folderExists(_ path: String, in workspace: URL) -> Bool {
        (try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + path)) != nil
    }

    /// The bot's running process when it runs this harness on the bot's own home.
    static func liveProcess(_ provider: HarnessProvider, _ context: HarnessSessionCleanupContext) -> (any AgentRuntimeProcess)? {
        guard !context.extendedAccess, let process = context.process(),
              process.configuration.harnessIdentifier == provider.rawValue else { return nil }
        return process
    }

    /// Has a running harness delete its old sessions over its own connection, waiting for it to finish.
    static func cleanUpLive(_ process: any AgentRuntimeProcess, before cutoff: Date) async -> SessionCleanupOutcome {
        let wait = SessionCleanupWait()
        return await withCheckedContinuation { continuation in
            wait.continuation = continuation
            if !process.cleanUpSessions(before: cutoff, completion: { wait.finish(.done) }) { wait.finish(.busy) }
            // A harness that dies mid-cleanup never calls back; the next round asks again.
            Task { try? await Task.sleep(for: .seconds(600)); wait.finish(.done) }
        }
    }
}

@MainActor private final class SessionCleanupWait {
    var continuation: CheckedContinuation<SessionCleanupOutcome, Never>?
    func finish(_ outcome: SessionCleanupOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// Claude Code offers no way for a bot's harness to delete a session, so its transcripts go as files, also while
/// it runs: it only appends to the session it is in, which stays. It runs without the account's skills and
/// plugins, so the copies it synced before go too.
struct ClaudeSessionCleaner: HarnessSessionCleaner {
    let provider = HarnessProvider.claudeCode
    func isPresent(in workspace: URL) -> Bool { HarnessSessionCleaners.folderExists(".claude", in: workspace) }
    func cleanUp(_ context: HarnessSessionCleanupContext) async -> SessionCleanupOutcome {
        let (workspace, kept, cutoff) = (context.workspace, context.kept, context.cutoff)
        await Task.detached(priority: .utility) {
            HarnessSessionCleanup.removeClaudeAccountSync(workspace: workspace)
            HarnessSessionCleanup.sweepClaude(workspace: workspace, keeping: kept, before: cutoff)
        }.value
        return .done
    }
}

/// Grok Build lists sessions over ACP but cannot delete one there, and its own command left the session's
/// folder behind, so its folders go as files; it lists the rest without complaint.
struct GrokSessionCleaner: HarnessSessionCleaner {
    let provider = HarnessProvider.grokBuild
    func isPresent(in workspace: URL) -> Bool { HarnessSessionCleaners.folderExists(".grok/sessions", in: workspace) }
    func cleanUp(_ context: HarnessSessionCleanupContext) async -> SessionCleanupOutcome {
        let (workspace, kept, cutoff) = (context.workspace, context.kept, context.cutoff)
        await Task.detached(priority: .utility) { HarnessSessionCleanup.sweepGrok(workspace: workspace, keeping: kept, before: cutoff) }.value
        return .done
    }
}

/// FX offers no way to delete a session over ACP, so its folders go as files; it lists the rest and records the
/// removed ones deleted in its own index.
struct FXSessionCleaner: HarnessSessionCleaner {
    let provider = HarnessProvider.fx
    func isPresent(in workspace: URL) -> Bool { HarnessSessionCleaners.folderExists(".fx/sessions/v2", in: workspace) }
    func cleanUp(_ context: HarnessSessionCleanupContext) async -> SessionCleanupOutcome {
        let (workspace, kept, cutoff) = (context.workspace, context.kept, context.cutoff)
        await Task.detached(priority: .utility) { HarnessSessionCleanup.sweepFX(workspace: workspace, keeping: kept, before: cutoff) }.value
        return .done
    }
}

/// Codex deletes its own threads: over the bot's running Codex when there is one, or else a Codex started for
/// the bot just for this. When neither can be, because the bot runs another harness, which a second start would
/// stop, or Codex is missing or will not start, its history goes as files once untouched for the retention
/// period; a bot that switches back to Codex starts a fresh thread and rebuilds its context from the conversation.
struct CodexSessionCleaner: HarnessSessionCleaner {
    let provider = HarnessProvider.codex
    func isPresent(in workspace: URL) -> Bool { HarnessSessionCleaners.folderExists(".codex", in: workspace) }

    func cleanUp(_ context: HarnessSessionCleanupContext) async -> SessionCleanupOutcome {
        // Codex runs with plugins off, so what it fetched for them goes whether or not it is running.
        let workspace = context.workspace
        await Task.detached(priority: .utility) { HarnessSessionCleanup.removeCodexPluginCaches(workspace: workspace) }.value
        if let process = HarnessSessionCleaners.liveProcess(provider, context) {
            return await HarnessSessionCleaners.cleanUpLive(process, before: context.cutoff)
        }
        if context.process() != nil {
            await removeHistory(context)
            return .done
        }
        guard let deletion = CodexThreadDeletion(workspace: context.workspace, before: context.cutoff, keeping: context.kept) else { return .done }
        let ran = await context.whileStopped {
            var deleted = false
            if let executable = context.executable(.codex), let connection = try? context.connect() {
                let harness = TemporaryHarness(connection: connection)
                deleted = await delete(deletion, through: harness, executable: executable, agentID: context.agentID)
                await harness.stop()
            }
            if !deleted { await removeHistory(context) }
        }
        if !ran { await removeHistory(context) }
        return .done
    }

    /// Starts the bot's Codex, restricted to its own home, without opening a thread, and deletes through it.
    /// False when Codex never got as far as answering.
    private func delete(_ deletion: CodexThreadDeletion, through harness: TemporaryHarness, executable: URL, agentID: UUID) async -> Bool {
        guard await harness.start(provider: .codex, agentID: agentID, executable: executable),
              await harness.request("initialize", params: CodexThreadDeletion.initializeParameters)?["result"] != nil else { return false }
        harness.notify("initialized")
        var deletion = deletion
        while let next = deletion.next() {
            let reply = await harness.request(next.method, params: next.params, timeout: next.step == .vacuum ? 600 : 120)
            guard let reply else { break }
            deletion.answered(next.step, succeeded: reply["result"] != nil)
        }
        return true
    }

    /// The history goes only when nothing runs Codex on this home, and nothing in it changed since the cutoff.
    private func removeHistory(_ context: HarnessSessionCleanupContext) async {
        guard HarnessSessionCleaners.liveProcess(provider, context) == nil else { return }
        let (workspace, cutoff) = (context.workspace, context.cutoff)
        await Task.detached(priority: .utility) { HarnessSessionCleanup.removeCodexHistory(workspace: workspace, before: cutoff) }.value
    }
}

/// An ACP harness that says it can list and delete sessions deletes its own: over the bot's running harness, or
/// else one started for the bot just for this. Their files are not removed by hand: OpenCode keeps its sessions
/// in the database that holds the bot's login, and Devin's layout is its own.
struct ACPSessionCleaner: HarnessSessionCleaner {
    let provider: HarnessProvider
    /// Where the harness keeps its data in the bot's home.
    let folder: String
    func isPresent(in workspace: URL) -> Bool { HarnessSessionCleaners.folderExists(folder, in: workspace) }

    func cleanUp(_ context: HarnessSessionCleanupContext) async -> SessionCleanupOutcome {
        if let process = HarnessSessionCleaners.liveProcess(provider, context) {
            return await HarnessSessionCleaners.cleanUpLive(process, before: context.cutoff)
        }
        guard context.process() == nil, let executable = context.executable(provider) else { return .done }
        _ = await context.whileStopped {
            guard let connection = try? context.connect() else { return }
            let harness = TemporaryHarness(connection: connection)
            await delete(through: harness, executable: executable, context: context)
            await harness.stop()
        }
        return .done
    }

    private func delete(through harness: TemporaryHarness, executable: URL, context: HarnessSessionCleanupContext) async {
        guard await harness.start(provider: provider, agentID: context.agentID, executable: executable),
              let initialized = await harness.request("initialize", params: FxProtocol.initializeParameters)?["result"] as? [String: Any],
              ACPSessionDeletion.isOffered(byInitializeResult: initialized) else { return }
        var deletion = ACPSessionDeletion(workspace: context.workspace, before: context.cutoff, keeping: context.kept)
        while let next = deletion.next() {
            guard let reply = await harness.request(next.method, params: next.params) else { break }
            deletion.answered(next.step, result: reply["result"] as? [String: Any], failed: reply["error"] != nil)
        }
    }
}

/// Deletes old Codex threads one request at a time, so a running bot's own requests are not held up behind
/// many, then vacuums its history. Used over a bot's running Codex and over one started just for this.
struct CodexThreadDeletion {
    enum Step: Equatable { case delete, vacuum }

    static let initializeParameters: [String: Any] = [
        "clientInfo": ["name": "noodle", "title": "Noodle",
                       "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"],
        "capabilities": ["experimentalApi": true]
    ]

    private let workspace: URL
    private var threads: [String]
    private var databases: [URL]
    private var deleted = 0

    /// Nil when no thread but those kept was last used before `cutoff`.
    init?(workspace: URL, before cutoff: Date, keeping kept: Set<String>) {
        let threads = HarnessSessionCleanup.codexThreads(workspace: workspace, before: cutoff).filter { !kept.contains($0.lowercased()) }
        // Codex refuses to delete a thread while its archive folder is missing, as it is in a bot's home.
        guard !threads.isEmpty,
              (try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex/archived_sessions", create: true)) != nil else { return nil }
        self.workspace = workspace
        self.threads = threads
        databases = HarnessSessionCleanup.codexHistoryDatabases(workspace: workspace)
    }

    /// The next request to send, or nil when done.
    mutating func next() -> (step: Step, method: String, params: [String: Any])? {
        if let thread = threads.popLast() { return (.delete, "thread/delete", ["threadId": thread]) }
        guard deleted > 0, let database = databases.popLast() else { return nil }
        // Deleted threads leave free pages that Codex never vacuums, so the file keeps its size. The vacuum is
        // a write to the bot's database, so it runs as a command in the bot's own sandbox, never in Noodle.
        return (.vacuum, "command/exec", [
            "command": ["/usr/bin/sqlite3", database.path, "PRAGMA incremental_vacuum;"],
            "cwd": workspace.path,
            "sandboxPolicy": ["type": "externalSandbox", "networkAccess": "restricted"],
            "timeoutMs": 600_000
        ])
    }

    /// A thread Codex will not delete, or a vacuum the sandbox refuses, leaves things as they were.
    mutating func answered(_ step: Step, succeeded: Bool) {
        if step == .delete, succeeded { deleted += 1 }
    }
}

/// Lists an ACP harness's sessions in the bot's workspace, page by page, then deletes the old ones one request
/// at a time. Used over a bot's running harness and over one started just for this.
struct ACPSessionDeletion {
    enum Step: Equatable { case list, delete }

    static func isOffered(byInitializeResult result: [String: Any]) -> Bool {
        let sessions = (result["agentCapabilities"] as? [String: Any])?["sessionCapabilities"] as? [String: Any]
        return sessions?["list"] != nil && sessions?["delete"] != nil
    }

    private let workspace: URL
    private let cutoff: Date
    private let kept: Set<String>
    private var listing = true
    private var cursor: String?
    private var pages = 0
    private var sessions: [String] = []

    init(workspace: URL, before cutoff: Date, keeping kept: Set<String>) {
        self.workspace = workspace
        self.cutoff = cutoff
        self.kept = kept
    }

    mutating func next() -> (step: Step, method: String, params: [String: Any])? {
        if listing {
            var params: [String: Any] = ["cwd": workspace.path]
            if let cursor { params["cursor"] = cursor }
            return (.list, "session/list", params)
        }
        guard let session = sessions.popLast() else { return nil }
        return (.delete, "session/delete", ["sessionId": session])
    }

    /// A list the harness refuses ends the cleanup; a session it will not delete is left as it is.
    mutating func answered(_ step: Step, result: [String: Any]?, failed: Bool) {
        guard step == .list else { return }
        guard !failed, let result else { listing = false; sessions = []; return }
        for session in result["sessions"] as? [[String: Any]] ?? [] {
            guard let id = session["sessionId"] as? String, FxProtocol.validIdentifier(id), !kept.contains(id.lowercased()),
                  (session["cwd"] as? String).map({ $0 == workspace.path }) ?? true,
                  let updated = (session["updatedAt"] as? String).flatMap(Self.date), updated < cutoff else { continue }
            sessions.append(id)
        }
        pages += 1
        cursor = result["nextCursor"] as? String
        if cursor == nil || pages >= 50 { listing = false }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// A harness started for a bot outside its runtime, restricted to the bot's own home, to answer a few requests.
@MainActor final class TemporaryHarness {
    private let connection: any HarnessRuntimeConnection
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any]?, Never>] = [:]
    private var ended = false
    private var stopped = false

    init(connection: any HarnessRuntimeConnection) {
        self.connection = connection
        let reader = JSONLineReader { [weak self] message in
            Task { @MainActor in self?.receive(message) }
        }
        self.connection.onData = { data, isError in if !isError { reader.receive(data) } }
        self.connection.onExit = { [weak self] _ in Task { @MainActor in self?.end() } }
        self.connection.onFailure = { [weak self] _ in Task { @MainActor in self?.end() } }
    }

    func start(provider: HarnessProvider, agentID: UUID, executable: URL) async -> Bool {
        let wait = TemporaryHarnessStart()
        return await withCheckedContinuation { continuation in
            wait.continuation = continuation
            connection.startHarness(provider: provider, agentID: agentID, executablePath: executable.path,
                                    extendedAccess: false, appsEnabled: false, sessionID: nil, resumeSession: false,
                                    modelIdentifier: nil, effortIdentifier: nil) { _, error in
                Task { @MainActor in wait.finish(error == nil) }
            }
            Task { try? await Task.sleep(for: .seconds(60)); wait.finish(false) }
        }
    }

    /// The reply, an error or a result, or nil when the harness ended or did not answer in time.
    func request(_ method: String, params: [String: Any], timeout: TimeInterval = 120) async -> [String: Any]? {
        guard !ended else { return nil }
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    func notify(_ method: String) { send(["jsonrpc": "2.0", "method": method, "params": [String: Any]()]) }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        end()
        let wait = TemporaryHarnessStart()
        _ = await withCheckedContinuation { continuation in
            wait.continuation = continuation
            connection.stop { _ in Task { @MainActor in wait.finish(true) } }
            Task { try? await Task.sleep(for: .seconds(30)); wait.finish(false) }
        }
        connection.invalidate()
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        connection.write(data + Data([10]))
    }

    private func receive(_ message: [String: Any]) {
        if message["method"] != nil {
            // The harness's own requests, such as for permission, are refused: nothing here runs a turn.
            if let id = message["id"] {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported client request"]])
            }
            return
        }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: message)
    }

    private func end() {
        ended = true
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(returning: nil) }
    }
}

@MainActor private final class TemporaryHarnessStart {
    var continuation: CheckedContinuation<Bool, Never>?
    func finish(_ started: Bool) {
        continuation?.resume(returning: started)
        continuation = nil
    }
}
