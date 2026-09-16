import Foundation

/// Display-only events. Never serializes model instructions or reasoning.
public enum AppleActivityEvent: Sendable {
    case status(String)
    case toolStarted(id: String, name: String, input: [String: String])
    case toolFinished(id: String, name: String, input: [String: String], output: String, failed: Bool, seconds: Double)

    public func message(sessionID: String) -> [String: Any] {
        let update: [String: Any]
        switch self {
        case .status(let title):
            update = ["sessionUpdate": "noodle_activity", "title": Self.bounded(title)]
        case .toolStarted(let id, let name, let input):
            update = ["sessionUpdate": "tool_call", "toolCallId": id, "title": name,
                      "status": "in_progress", "rawInput": input.mapValues(Self.bounded)]
        case .toolFinished(let id, let name, let input, let output, let failed, let seconds):
            update = ["sessionUpdate": "tool_call_update", "toolCallId": id, "title": name,
                      "status": failed ? "failed" : "completed", "rawInput": input.mapValues(Self.bounded),
                      "content": [["type": "content", "content": ["type": "text",
                          "text": "Duration: \(String(format: "%.2f", seconds))s\n" + Self.bounded(output)]]]]
        }
        return ["method": "session/update", "params": ["sessionId": sessionID, "update": update]]
    }

    private static func bounded(_ value: String) -> String {
        guard value.utf8.count > 12_288 else { return value }
        return String(decoding: value.utf8.prefix(12_288), as: UTF8.self) + "\n[Activity preview truncated]"
    }
}

struct AppleToolResult {
    let text: String
    var failed = false
}

enum AppleToolActivity {
    static func perform(name: String, input: [String: String],
                        onEvent: @escaping @Sendable (AppleActivityEvent) async -> Void,
                        operation: () async throws -> AppleToolResult) async throws -> String {
        let id = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        await onEvent(.toolStarted(id: id, name: name, input: input))
        do {
            let result = try await operation()
            await onEvent(.toolFinished(id: id, name: name, input: input, output: result.text,
                failed: result.failed, seconds: ProcessInfo.processInfo.systemUptime - started))
            return result.text
        } catch {
            let text = error is CancellationError ? "Cancelled." : "Tool failed: \(error.localizedDescription)"
            await onEvent(.toolFinished(id: id, name: name, input: input, output: text, failed: true,
                seconds: ProcessInfo.processInfo.systemUptime - started))
            if error is CancellationError || error is AppleToolLimit { throw error }
            return text
        }
    }
}
