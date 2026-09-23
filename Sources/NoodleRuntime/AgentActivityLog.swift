import Foundation
import NoodleCore

/// Display-only observations. These never acknowledge messages or drive a runtime.
package struct AgentActivityEvent {
    var title: String
    var detail = ""
    var streamID: String? = nil
    var appending = false

    package init(title: String, detail: String = "", streamID: String? = nil, appending: Bool = false) {
        self.title = title
        self.detail = detail
        self.streamID = streamID
        self.appending = appending
    }
}

package struct AgentActivityEntry: Equatable {
    package let id: UUID
    let date: Date
    var title: String
    var detail: String
    var streamID: String?

    package var text: String {
        let time = date.formatted(.dateTime.hour().minute().second())
        let output = detail.trimmingCharacters(in: .newlines)
        return "[\(time)] \(title)\n" + (output.isEmpty ? "" : "\(output)\n")
    }

    var byteCount: Int { title.utf8.count + detail.utf8.count + (streamID?.utf8.count ?? 0) }
}

@MainActor
package final class AgentActivityLog {
    package private(set) var entries: [AgentActivityEntry] = []
    package private(set) var revision = 0
    private(set) var byteCount = 0
    private(set) var status = "Not started"
    private var phase: AgentRuntimePhase?
    private let entryLimit: Int
    private let byteLimit: Int

    init(entryLimit: Int = 500, byteLimit: Int = 256 * 1024) {
        self.entryLimit = max(1, entryLimit)
        self.byteLimit = max(1024, byteLimit)
    }

    package func record(_ event: AgentActivityEvent, at date: Date = Date()) {
        let title = Self.bounded(event.title, bytes: 256)
        let streamID = event.streamID.map { Self.bounded($0, bytes: 512) }
        let detail = Self.bounded(event.detail, bytes: min(16 * 1024, byteLimit - 768))
        if let streamID, let index = entries.lastIndex(where: { $0.streamID == streamID }) {
            byteCount -= entries[index].byteCount
            entries[index].title = title
            entries[index].detail = event.appending
                ? Self.bounded(entries[index].detail + detail, bytes: min(16 * 1024, byteLimit - 768))
                : detail
            byteCount += entries[index].byteCount
        } else {
            let entry = AgentActivityEntry(id: UUID(), date: date, title: title, detail: detail, streamID: streamID)
            entries.append(entry)
            byteCount += entry.byteCount
        }
        while entries.count > entryLimit || byteCount > byteLimit {
            byteCount -= entries.removeFirst().byteCount
        }
        revision &+= 1
    }

    func record(_ snapshot: AgentRuntimeSnapshot) {
        guard phase != snapshot.phase || status != snapshot.detail else { return }
        phase = snapshot.phase
        status = snapshot.detail
        // End stream coalescing at lifecycle boundaries, including a new turn.
        for index in entries.indices {
            byteCount -= entries[index].streamID?.utf8.count ?? 0
            entries[index].streamID = nil
        }
        record(.init(title: snapshot.detail))
    }

    package func clear() {
        entries.removeAll()
        byteCount = 0
        revision &+= 1
    }

    package var text: String { entries.map(\.text).joined() }

    /// Retain recent output, trim oversized payloads, and remove terminal controls.
    static func bounded(_ text: String, bytes: Int) -> String {
        let suffix = text.utf8.suffix(bytes)
        let cleaned = String(decoding: suffix, as: UTF8.self).unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(cleaned))
        return text.utf8.count > bytes ? "…\n" + result : result
    }
}

@MainActor
package final class AgentActivityStore {
    private var logs: [UUID: AgentActivityLog] = [:]

    package func log(for agentID: UUID) -> AgentActivityLog {
        if let log = logs[agentID] { return log }
        let log = AgentActivityLog()
        logs[agentID] = log
        return log
    }

    func record(_ message: [String: Any], provider: HarnessProvider, agentID: UUID) {
        for event in AgentActivityParser.events(message, provider: provider) {
            log(for: agentID).record(event)
        }
    }

    func recordSnapshots(_ snapshots: [UUID: AgentRuntimeSnapshot]) {
        for (id, snapshot) in snapshots { log(for: id).record(snapshot) }
    }

    func retainAgents(_ ids: Set<UUID>) {
        logs = logs.filter { ids.contains($0.key) }
    }
}
