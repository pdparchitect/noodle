import Foundation
import OSLog
import Darwin

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
        case inboxSteerSubmitted = "inbox-steer-submitted"
        case inboxSteerRejected = "inbox-steer-rejected"
        case turnInterruptRequested = "turn-interrupt-requested"
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

    /// Bounded metadata snapshot, not an inbox or an agent-facing protocol.
    struct InboxReceipt: Codable, Equatable {
        let context: Context
        var reads = 0
        var failures = 0
        var deliveries = 0
    }

    static func receiptURL(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".noodle/runtime-log-inbox.json")
    }

    static func readReceipt(in workspace: URL, context: Context) -> InboxReceipt? {
        guard let mailbox = try? WorkspaceMailbox(workspace: workspace, path: ".noodle"),
              let data = try? mailbox.read("runtime-log-inbox.json", limit: 4096),
              let receipt = try? JSONDecoder().decode(InboxReceipt.self, from: data),
              receipt.context == context,
              (0...1_000_000).contains(receipt.reads),
              (0...1_000_000).contains(receipt.failures),
              (0...1_000_000_000).contains(receipt.deliveries) else { return nil }
        return receipt
    }

    private static func saveInboxReceipt(in workspace: URL, context: Context, count: Int?) {
        guard let mailbox = try? WorkspaceMailbox(workspace: workspace, path: ".noodle") else { return }
        mailbox.withLock("runtime-log-inbox.lock") {
            guard readContext(in: workspace, agentID: context.agentID) == context else { return }
            var receipt = readReceipt(in: workspace, context: context) ?? InboxReceipt(context: context)
            if let count {
                receipt.reads = min(receipt.reads + 1, 1_000_000)
                receipt.deliveries = min(receipt.deliveries + min(max(0, count), 1_000_000_000), 1_000_000_000)
            } else {
                receipt.failures = min(receipt.failures + 1, 1_000_000)
            }
            if let data = try? JSONEncoder().encode(receipt) {
                try? mailbox.writeData(data, named: "runtime-log-inbox.json")
            }
        }
    }

    static func relayInboxReceipt(in workspace: URL, context: Context) {
        guard let receipt = readReceipt(in: workspace, context: context) else { return }
        if receipt.reads > 0 {
            record(.inboxRead, agentID: context.agentID, provider: context.provider,
                   context: context, count: receipt.deliveries, reads: receipt.reads)
        }
        if receipt.failures > 0 {
            record(.inboxReadFailed, agentID: context.agentID, provider: context.provider,
                   context: context, reads: receipt.failures)
        }
        (try? WorkspaceMailbox(workspace: workspace, path: ".noodle"))?.remove("runtime-log-inbox.json")
    }

    static func contextURL(in workspace: URL) -> URL {
        workspace.appendingPathComponent(".noodle/runtime-log-context.json")
    }

    static func readContext(in workspace: URL, agentID: UUID) -> Context? {
        guard let mailbox = try? WorkspaceMailbox(workspace: workspace, path: ".noodle"),
              let data = try? mailbox.read("runtime-log-context.json", limit: 4096),
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

    static func record(_ event: Event, agentID: UUID, provider: HarnessProvider?, context: Context?, count: Int = 0, reads: Int = 0) {
        let providerName = provider?.rawValue ?? "unknown"
        let wake = context?.wakeID.uuidString ?? "uncorrelated"
        let reason = context?.reason ?? "none"
        switch event {
        case .runtimeDisconnected, .runtimeFailed, .turnFailed, .inboxReadFailed:
            logger.error("event=\(event.rawValue, privacy: .public) bot=\(agentID.uuidString, privacy: .public) harness=\(providerName, privacy: .public) wake=\(wake, privacy: .public) reason=\(reason, privacy: .public) count=\(count) reads=\(reads)")
        default:
            logger.notice("event=\(event.rawValue, privacy: .public) bot=\(agentID.uuidString, privacy: .public) harness=\(providerName, privacy: .public) wake=\(wake, privacy: .public) reason=\(reason, privacy: .public) count=\(count) reads=\(reads)")
        }
    }

    public static func inboxRead(agentID: UUID, workspace: URL, count: Int?, consuming: Bool) {
        let context = readContext(in: workspace, agentID: agentID)
        if consuming {
            if let context {
                // Sandboxed harness commands may not reach logd. The app emits
                // this receipt when the turn ends, using the captured wake ID.
                saveInboxReceipt(in: workspace, context: context, count: count)
            } else {
                record(count == nil ? .inboxReadFailed : .inboxRead, agentID: agentID,
                       provider: nil, context: nil, count: count ?? 0, reads: 1)
            }
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
        do {
            let mailbox = try WorkspaceMailbox(workspace: workspace, path: ".noodle", create: true)
            try mailbox.write(context, named: "runtime-log-context.json")
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
        if let previous = RuntimeDiagnostics.readContext(in: workspace, agentID: agentID) {
            RuntimeDiagnostics.relayInboxReceipt(in: workspace, context: previous)
            (try? WorkspaceMailbox(workspace: workspace, path: ".noodle"))?.remove("runtime-log-context.json")
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
        if let context { RuntimeDiagnostics.relayInboxReceipt(in: workspace, context: context) }
        record(event)
        // An older runtime must not clear a newer runtime's correlation marker.
        if let context, RuntimeDiagnostics.readContext(in: workspace, agentID: agentID) == context {
            (try? WorkspaceMailbox(workspace: workspace, path: ".noodle"))?.remove("runtime-log-context.json")
        }
        context = nil
    }
}
