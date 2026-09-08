import Foundation
import OSLog

/// Diagnostics only: no messages, tool arguments, names, paths, or raw errors.
public enum RuntimeDiagnostics {
    public static let subsystem = "com.pdparchitect.noodle.runtime"
    private static let logger = Logger(subsystem: subsystem, category: "lifecycle")

    public enum Event: String {
        case runtimeStarting = "runtime-starting"
        case runtimeStopped = "runtime-stopped"
        case runtimeDisconnected = "runtime-disconnected"
        case runtimeFailed = "runtime-failed"
        case wakePrepared = "wake-prepared"
        case wakeSubmitted = "wake-submitted"
        case turnAccepted = "turn-accepted"
        case turnOutputObserved = "turn-output-observed"
        case turnCompleted = "turn-completed"
        case turnEndedUnknown = "turn-ended-unknown"
        case turnInterrupted = "turn-interrupted"
        case turnFailed = "turn-failed"
        case inboxRead = "inbox-read"
        case inboxReadFailed = "inbox-read-failed"
    }

    // The CLI is a separate process. This small, replaceable marker lets its logs
    // share the current wake ID without asking the agent to pass extra arguments.
    // It is neither an acknowledgement nor work state, and is never used to drive work.
    struct Context: Codable, Equatable {
        let agentID: UUID
        let wakeID: UUID
        let provider: HarnessProvider
        let reason: String
    }

    static func contextURL(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".noodle/runtime-log-context.json")
    }

    static func readContext(in workspace: URL, agentID: UUID) -> Context? {
        guard hasSafeContextDirectory(in: workspace),
              let data = try? Data(contentsOf: contextURL(in: workspace)),
              let context = try? JSONDecoder().decode(Context.self, from: data),
              context.agentID == agentID,
              AgentWakeReason(rawValue: context.reason) != nil else { return nil }
        return context
    }

    static func hasSafeContextDirectory(in workspace: URL) -> Bool {
        let directory = contextURL(in: workspace).deletingLastPathComponent()
        return directory.resolvingSymlinksInPath().standardizedFileURL
            == workspace.resolvingSymlinksInPath().appendingPathComponent(".noodle").standardizedFileURL
    }

    static func record(_ event: Event, agentID: UUID, provider: HarnessProvider?, context: Context?, count: Int = 0) {
        let providerName = provider?.rawValue ?? "unknown"
        let wake = context?.wakeID.uuidString ?? "uncorrelated"
        let reason = context?.reason ?? "none"
        switch event {
        case .runtimeDisconnected, .runtimeFailed, .turnFailed, .inboxReadFailed:
            logger.error("event=\(event.rawValue, privacy: .public) bot=\(agentID.uuidString, privacy: .public) harness=\(providerName, privacy: .public) wake=\(wake, privacy: .public) reason=\(reason, privacy: .public) count=\(count)")
        default:
            logger.notice("event=\(event.rawValue, privacy: .public) bot=\(agentID.uuidString, privacy: .public) harness=\(providerName, privacy: .public) wake=\(wake, privacy: .public) reason=\(reason, privacy: .public) count=\(count)")
        }
    }

    public static func inboxRead(agentID: UUID, workspace: URL, count: Int?, consuming: Bool) {
        let context = readContext(in: workspace, agentID: agentID)
        if consuming {
            record(count == nil ? .inboxReadFailed : .inboxRead, agentID: agentID,
                   provider: context?.provider, context: context, count: count ?? 0)
        }
        #if DEBUG
        logger.debug("inbox-inspected bot=\(agentID.uuidString, privacy: .public) consuming=\(consuming) count=\(count ?? -1)")
        #endif
    }

    public static func notificationQueued(agentID: UUID, coalesced: Bool) {
        #if DEBUG
        logger.debug("notification-queued bot=\(agentID.uuidString, privacy: .public) coalesced=\(coalesced)")
        #endif
    }
}

/// Owned by a single runtime on the main actor. Logging failures must never stop work.
public struct RuntimeTrace {
    private let agentID: UUID
    private let provider: HarnessProvider
    private let workspace: URL
    private var context: RuntimeDiagnostics.Context?
    private var observedOutput = false

    public init(agentID: UUID, provider: HarnessProvider, workspace: URL) {
        self.agentID = agentID
        self.provider = provider
        self.workspace = workspace
    }

    public mutating func begin(reason: AgentWakeReason) {
        context = .init(agentID: agentID, wakeID: UUID(), provider: provider, reason: reason.rawValue)
        observedOutput = false
        let url = RuntimeDiagnostics.contextURL(in: workspace)
        do {
            guard RuntimeDiagnostics.hasSafeContextDirectory(in: workspace) else {
                record(.wakePrepared)
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(context).write(to: url, options: .atomic)
        } catch {
            // Best effort only. Lifecycle records still carry the in-memory wake ID.
        }
        record(.wakePrepared)
    }

    public func record(_ event: RuntimeDiagnostics.Event) {
        RuntimeDiagnostics.record(event, agentID: agentID, provider: provider, context: context)
    }

    public mutating func runtimeStarting() {
        // Discard a marker left by an abrupt app exit. It cannot prove anything
        // about a newly started runtime's subsequent CLI calls.
        if RuntimeDiagnostics.readContext(in: workspace, agentID: agentID) != nil {
            try? FileManager.default.removeItem(at: RuntimeDiagnostics.contextURL(in: workspace))
        }
        context = nil
        record(.runtimeStarting)
    }

    public mutating func outputObserved() {
        guard context != nil, !observedOutput else { return }
        observedOutput = true
        record(.turnOutputObserved)
    }

    public mutating func finish(_ event: RuntimeDiagnostics.Event) {
        record(event)
        // An older runtime must not clear a newer runtime's correlation marker.
        if let context, RuntimeDiagnostics.readContext(in: workspace, agentID: agentID) == context {
            try? FileManager.default.removeItem(at: RuntimeDiagnostics.contextURL(in: workspace))
        }
        context = nil
    }
}
