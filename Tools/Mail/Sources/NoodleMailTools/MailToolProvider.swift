import Foundation
import MailBridge
import NoodleCore

/// Noodle Mail as tools. Which mailboxes a bot may use is decided and enforced by Noodle's broker
/// before a call arrives here; this provider only translates and forwards.
public struct MailToolProvider: ToolProvider {
    public typealias Transport = @Sendable (MailRequest) async throws -> MailResponse
    public let kind = ToolProviderKind.appExtension
    public let manifest = ToolProviderManifest(
        id: "mail", title: "Noodle Mail",
        summary: "Read the mailboxes assigned to this bot: list, search and read mail, and save attachments.",
        instructions: MailToolGuidance.instructions,
        activation: .whenAssigned("mailbox"))
    private let transport: Transport

    public init(transport: @escaping Transport) { self.transport = transport }

    // MARK: Tool list

    public func tools(context: ToolCallContext) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tools": MailOperation.allCases.map(Self.tool)], options: [.sortedKeys])
    }

    private static func tool(_ operation: MailOperation) -> [String: Any] {
        let string: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let integer: (String) -> [String: Any] = { ["type": "integer", "description": $0] }
        let boolean: (String) -> [String: Any] = { ["type": "boolean", "description": $0] }
        var properties: [String: [String: Any]] = [:], required: [String] = []
        if operation != .mailboxes {
            properties["mailbox"] = ["type": "string", "format": "noodle-resource", "noodle/kind": "mailbox", "description": "Assigned mailbox ID from mailboxes."]
            required.append("mailbox")
        }
        switch operation {
        case .mailboxes, .folders:
            break
        case .list, .search:
            properties["folder"] = string("Folder name exactly as folders gives it in name. Default INBOX.")
            properties["unread"] = boolean("Only unread mail.")
            properties["limit"] = integer("Rows to return, 1 to 100, newest first. Default 20.")
            properties["before_uid"] = integer("Only mail with a smaller UID: the next page after the last row you saw.")
            if operation == .search {
                properties["from"] = string("The sender contains this.")
                properties["to"] = string("A recipient contains this.")
                properties["subject"] = string("The subject contains this.")
                properties["text"] = string("The headers or the body contain this.")
                properties["since"] = string("On or after this day, YYYY-MM-DD.")
                properties["before"] = string("Before this day, YYYY-MM-DD; the day itself is excluded.")
            }
        case .read:
            properties["uid"] = integer("The message UID from list or search.")
            properties["folder"] = string("The folder the UID came from, as folders names it. Default INBOX.")
            properties["mark_read"] = boolean("Also mark the message as read. Default false.")
            properties["max_chars"] = integer("Most characters of text to return, 1000 to 200000. Default 20000.")
            required.append("uid")
        case .attachment:
            properties["uid"] = integer("The message UID.")
            properties["part"] = string("The attachment's part, from read.")
            properties["folder"] = string("The folder the UID came from. Default INBOX.")
            properties["output"] = ["type": "string", "format": "noodle-file", "noodle/access": "write", "description": "A new workspace file to save the attachment to."]
            required += ["uid", "part", "output"]
        }
        // The broker's limit sits above the socket's, so a slow start of Noodle Mail still gets its answer.
        var meta: [String: Any] = ["noodle/timeout": operation.timeout + 30]
        if operation == .mailboxes { meta["noodle/resource-list"] = ["kind": "mailbox", "path": "mailboxes"] }
        var tool: [String: Any] = ["name": operation.rawValue, "description": MailToolGuidance.tool(operation), "_meta": meta,
                                   "inputSchema": ["type": "object", "properties": properties, "required": required]]
        if [.mailboxes, .folders, .list, .search].contains(operation) { tool["annotations"] = ["readOnlyHint": true, "idempotentHint": true] }
        return tool
    }

    // MARK: Calls

    public func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
        do {
            guard let operation = MailOperation(rawValue: tool) else { throw MailError("Noodle Mail has no tool named \(tool).") }
            let options = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            let request = try Self.request(operation, options: options)
            try request.validate()
            // Marking a message read changes the server and cannot be undone, so Noodle confirms the assignment right before the
            // read goes out. The mailbox list, which changes nothing, goes first: it starts Noodle Mail if needed, and those
            // seconds then pass before the question, not between it and the read.
            if operation == .read, request.markRead == true {
                _ = try await transport(MailRequest(.mailboxes)).checked()
                try await context.authorize()
            }
            let response = try await transport(request).checked()
            switch operation {
            case .mailboxes:
                let rows = (response.mailboxes ?? []).map { ["id": $0.id.uuidString, "name": $0.name, "address": $0.address] }
                return try Self.result(Self.count(rows.count, "mailbox", "mailboxes") + ".", ["mailboxes": rows])
            case .folders:
                let folders = response.folders ?? []
                return try Self.result(Self.count(folders.count, "folder", "folders") + ".", ["folders": try Self.json(folders)])
            case .list, .search:
                let rows = response.messages ?? []
                return try Self.result(rows.isEmpty ? "No messages." : Self.count(rows.count, "message", "messages") + ", newest first.",
                                       ["messages": try Self.json(rows)])
            case .read:
                guard let message = response.message else { throw MailError("Noodle Mail returned no message.") }
                return try Self.result(message.truncated ? "Message (text truncated)." : "Message.", ["message": try Self.json(message)])
            case .attachment:
                guard let data = response.attachment?.data else { throw MailError("Noodle Mail returned no attachment.") }
                guard let output = files.first(where: { $0.parameter == "output" }) else { throw MailError("Specify --output with a new workspace file.") }
                try output.handle.write(contentsOf: data)
                return try Self.result("Saved \(data.count) bytes.", ["saved": true, "size": data.count])
            }
        } catch {
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true],
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    static func request(_ operation: MailOperation, options: [String: Any]) throws -> MailRequest {
        func flag(_ name: String) -> String { "--" + name.replacingOccurrences(of: "_", with: "-") }
        func text(_ name: String) throws -> String? {
            guard let value = options[name] else { return nil }
            guard let string = value as? String else { throw MailError("\(flag(name)) must be text.") }
            return string
        }
        func int(_ name: String) throws -> Int? {
            guard let value = options[name] else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else {
                throw MailError("\(flag(name)) must be a whole number.")
            }
            return number.intValue
        }
        func bool(_ name: String) throws -> Bool? {
            guard let value = options[name] else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw MailError("\(flag(name)) must be true or false.") }
            return number.boolValue
        }
        var request = MailRequest(operation)
        if let mailbox = try text("mailbox") {
            guard let id = UUID(uuidString: mailbox) else { throw MailError("Invalid mailbox ID. Use an ID from mailboxes.") }
            request.mailboxID = id
        }
        request.folder = try text("folder")
        request.uid = try int("uid")
        request.part = try text("part")
        request.markRead = try bool("mark_read")
        request.maxCharacters = try int("max_chars")
        if operation == .list || operation == .search {
            var query = MailQuery()
            query.unreadOnly = try bool("unread")
            query.limit = try int("limit")
            query.beforeUID = try int("before_uid")
            if operation == .search {
                query.from = try text("from"); query.to = try text("to"); query.subject = try text("subject"); query.text = try text("text")
                query.since = try text("since"); query.before = try text("before")
            }
            request.query = query
        }
        return request
    }

    /// "1 folder", "2 folders": a count with its noun in the right number.
    private static func count(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }

    /// One line of text for people, and the data once, in structuredContent, for the bot. Slashes stay as they are: `\/` costs tokens.
    private static func result(_ text: String, _ structured: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "structuredContent": structured, "isError": false],
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
}
