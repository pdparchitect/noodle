import Foundation
import NoodleCore

/// Only consume public activity fields; initialization, auth, opaque reasoning,
/// raw stderr and transport responses are deliberately not dumped into the log.
enum AgentActivityParser {
    static func events(_ message: [String: Any], provider: HarnessProvider) -> [AgentActivityEvent] {
        switch provider {
        case .codex: return items(message)
        case .muse: return muse(message)
        case .claudeCode: return claude(message)
        case .fx, .grokBuild, .apple, .openCode: return acp(message, provider: provider)
        }
    }

    /// MSP v1 uses kind/itemId and item/delta field paths, not Codex item types.
    /// Field names follow the stable schema exported by `muse schema generate-ts`.
    private static func muse(_ message: [String: Any]) -> [AgentActivityEvent] {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return [] }
        if method == "view/gap" { return [.init(title: "Some activity was not delivered by Muse")] }
        if method == "item/delta" {
            guard let id = params["itemId"] as? String else { return [] }
            let field = params["field"] as? String ?? "text"
            guard field == "text" || field == "output" || field.hasPrefix("summary.") else { return [] }
            let title = field == "text" ? "Output" : (field == "output" ? "Tool output" : "Reasoning summary")
            return textEvent(title, params["delta"], stream: id + ":" + field, appending: true)
        }
        guard ["item/started", "item/updated", "item/completed"].contains(method),
              let item = params["item"] as? [String: Any],
              let id = item["itemId"] as? String, let kind = item["kind"] as? String else { return [] }
        let status = item["status"] as? String ?? "inProgress"
        switch kind {
        case "userMessage": return []
        case "agentMessage": return textEvent("Output", item["text"], stream: id + ":text")
        case "reasoning":
            return (item["summary"] as? [String] ?? []).enumerated().flatMap {
                textEvent("Reasoning summary", $0.element, stream: id + ":summary.\($0.offset)")
            }
        case "toolCall", "userShell":
            let name = kind == "userShell" ? "Command" : (item["tool"] as? String ?? "Tool")
            let input = item["args"] as? String ?? item["commandText"] as? String ?? ""
            let failure = item["failureReason"] as? String ?? ""
            return [.init(title: "\(name): \(status)", detail: [input, failure].filter { !$0.isEmpty }.joined(separator: "\n"), streamID: id)]
                + textEvent("Tool output", item["visibleOutput"], stream: id + ":output")
        default:
            return [.init(title: "\(kind): \(status)",
                          detail: item["fallbackText"] as? String ?? item["objective"] as? String ?? item["message"] as? String ?? "",
                          streamID: id)]
        }
    }

    private static func items(_ message: [String: Any]) -> [AgentActivityEvent] {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else { return [] }
        let scope = (params["turnId"] as? String ?? "") + ":"
        let id = params["itemId"] as? String
        let stream = id.map { scope + $0 }
        switch method {
        case "item/agentMessage/delta":
            return textEvent("Output", params["delta"], stream: stream, appending: true)
        case "item/reasoning/summaryTextDelta":
            return textEvent("Reasoning summary", params["delta"], stream: stream.map { $0 + ":summary" }, appending: true)
        case "item/commandExecution/outputDelta", "item/toolCall/outputDelta":
            return textEvent("Tool output", params["delta"], stream: stream.map { $0 + ":output" }, appending: true)
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else { return [] }
            let complete = method == "item/completed"
            let key = (item["id"] as? String).map { scope + $0 }
            switch type {
            case "agentMessage":
                return textEvent("Output", item["text"], stream: key)
            case "reasoning":
                let summary = (item["summary"] as? [String])?.joined(separator: "\n")
                return textEvent("Reasoning summary", summary, stream: key.map { $0 + ":summary" })
            case "commandExecution":
                let command = item["command"] as? String ?? ""
                let exit = (item["exitCode"] as? Int).map { " (exit \($0))" } ?? ""
                return [.init(title: complete ? "Command completed\(exit)" : "Running command",
                              detail: command, streamID: key)]
                    + (complete ? textEvent("Tool output", item["aggregatedOutput"], stream: key.map { $0 + ":output" }) : [])
            case "mcpToolCall", "dynamicToolCall", "toolCall", "tool_call":
                let name = item["tool"] as? String ?? item["name"] as? String ?? "Tool"
                let detail = item["arguments"].map(render) ?? ""
                return [.init(title: "\(name): \(complete ? "completed" : "started")", detail: detail, streamID: key)]
                    + (complete ? textEvent("Tool result", toolResult(item), stream: key.map { $0 + ":output" }) : [])
            case "fileChange":
                let changes = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                return [.init(title: complete ? "Files changed" : "Changing files", detail: changes.joined(separator: "\n"), streamID: key)]
            case "webSearch":
                return [.init(title: complete ? "Search completed" : "Searching", detail: item["query"] as? String ?? "", streamID: key)]
            default:
                // Newer harnesses can add item types independently. Show
                // their label, without serializing unfamiliar private payloads.
                guard !["userMessage", "reasoning"].contains(type) else { return [] }
                return [.init(title: "\(type): \(complete ? "completed" : "started")", streamID: key)]
            }
        default: return []
        }
    }

    private static func acp(_ message: [String: Any], provider: HarnessProvider) -> [AgentActivityEvent] {
        guard message["method"] as? String == "session/update",
              let params = message["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let type = update["sessionUpdate"] as? String else { return [] }
        switch type {
        case "noodle_activity" where provider == .apple:
            guard let title = update["title"] as? String, !title.isEmpty else { return [] }
            return [.init(title: title)]
        case "agent_message_chunk", "agent_thought_chunk":
            let text = contentText(update["content"])
            if provider == .apple && text == "Working" { return [.init(title: "Working", streamID: "apple-working")] }
            return textEvent(type == "agent_message_chunk" ? "Output" : "Reasoning summary", text,
                             stream: type, appending: true)
        case "tool_call", "tool_call_update":
            let id = update["toolCallId"] as? String
            let title = update["title"] as? String ?? "Tool"
            let rawStatus = update["status"] as? String ?? "started"
            let status = provider == .apple && rawStatus == "in_progress" ? "started" : rawStatus
            let detail = contentText(update["content"])
            let input = update["rawInput"].map(render) ?? ""
            // Updates may omit the initial title/input. Separate entries retain
            // that context and show the actual status supplied by the harness.
            return [.init(title: "\(title): \(status)", detail: [input, detail].filter { !$0.isEmpty }.joined(separator: "\n"),
                          streamID: id.map { $0 + ":" + status })]
        case "plan":
            let entries = (update["entries"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
                guard let text = entry["content"] as? String else { return nil }
                return "[\(entry["status"] as? String ?? "pending")] \(text)"
            }
            return textEvent("Plan", entries.joined(separator: "\n"), stream: "plan")
        default: return []
        }
    }

    private static func claude(_ message: [String: Any]) -> [AgentActivityEvent] {
        guard let type = message["type"] as? String, ["assistant", "user"].contains(type),
              let body = message["message"] as? [String: Any], let blocks = body["content"] as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text" where type == "assistant":
                guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                return .init(title: "Output", detail: text)
            case "tool_use" where type == "assistant":
                return .init(title: "\(block["name"] as? String ?? "Tool"): started", detail: block["input"].map(render) ?? "")
            case "tool_result":
                return .init(title: block["is_error"] as? Bool == true ? "Tool failed" : "Tool result", detail: contentText(block["content"]))
            default: return nil
            }
        }
    }

    private static func textEvent(_ title: String, _ value: Any?, stream: String? = nil, appending: Bool = false) -> [AgentActivityEvent] {
        guard let text = value as? String, !text.isEmpty else { return [] }
        return [.init(title: title, detail: text, streamID: stream, appending: appending)]
    }

    private static func toolResult(_ item: [String: Any]) -> String {
        if let error = item["error"] as? [String: Any], let text = error["message"] as? String { return text }
        if let result = item["result"] as? [String: Any] { return contentText(result["content"]) }
        return contentText(item["content"])
    }

    private static func contentText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let items = value as? [[String: Any]] { return items.map { contentText($0) }.filter { !$0.isEmpty }.joined(separator: "\n") }
        guard let object = value as? [String: Any] else { return "" }
        if object["type"] as? String == "text" { return object["text"] as? String ?? "" }
        if object["type"] as? String == "content" { return contentText(object["content"]) }
        if object["type"] as? String == "diff" {
            return [object["path"] as? String, object["newText"] as? String].compactMap { $0 }.joined(separator: "\n")
        }
        return ""
    }

    private static func render(_ value: Any) -> String {
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
