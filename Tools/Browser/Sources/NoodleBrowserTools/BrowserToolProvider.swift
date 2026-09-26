import BrowserBridge
import Darwin
import Foundation
import NoodleCore

/// Noodle Browser as tools. Which browsers a bot may use is decided and enforced by
/// Noodle's broker before a call arrives here; this provider only translates and forwards.
public struct BrowserToolProvider: ToolProvider {
    public typealias Transport = @Sendable (BrowserRequest) async throws -> BrowserResponse
    public let kind = ToolProviderKind.appExtension
    public let manifest = ToolProviderManifest(
        id: "browser", title: "Noodle Browser",
        summary: "Browse websites in the persistent Noodle Browser profiles assigned to this bot.",
        instructions: """
        Start with list and choose an assigned browser by its name and description. Every other tool takes --browser with that ID, and tab tools take --tab from open or tabs; keep the two together. Noodle Browser starts quietly when needed. Where the notes below say "command", read "tool": the options are the same, webmcp list and webmcp call are the tools webmcp-list and webmcp-call, and results arrive as JSON in structuredContent.

        \(BrowserToolGuidance.judgement)
        ## Reference

        \(BrowserToolGuidance.conventions)
        """,
        activation: .whenAssigned("browser"))
    private let transport: Transport
    private let stagingRoot: @Sendable () throws -> URL

    public init(stagingRoot: @escaping @Sendable () throws -> URL, transport: @escaping Transport) {
        self.stagingRoot = stagingRoot; self.transport = transport
    }

    // MARK: Tool list

    static var operations: [BrowserOperation] { BrowserOperation.agentCases }

    public func tools(context: ToolCallContext) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tools": Self.operations.map(Self.tool)], options: [.sortedKeys])
    }

    private static func tool(_ operation: BrowserOperation) -> [String: Any] {
        let string: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        var properties: [String: [String: Any]] = [:], required: [String] = []
        if operation != .list {
            properties["browser"] = ["type": "string", "format": "noodle-resource", "noodle/kind": "browser", "description": "Assigned browser ID from list."]
            required.append("browser")
        }
        if operation.needsTab || operation == .status {
            properties["tab"] = string("Tab ID from open or tabs.")
            if operation.needsTab { required.append("tab") }
        }
        let file: (String, String) -> [String: Any] = { ["type": "string", "format": "noodle-file", "noodle/access": $0, "description": $1] }
        let options: [String: [String: Any]] = [
            "url": string("HTTP or HTTPS URL."), "target": string("CSS selector."), "frame": string("Frame ID from the latest inspect."),
            "text": string("Text, keys or an async JavaScript function body."), "x": ["type": "number", "description": "Main-viewport x in points."],
            "y": ["type": "number", "description": "Main-viewport y in points."], "count": ["type": "integer", "description": "1 or 2 clicks."],
            "download": string("Download ID from downloads."), "accept": ["type": "boolean", "description": "Accept or dismiss the dialog."],
            "bookmark": string("Bookmark ID from bookmarks."), "title": string("Bookmark title."), "query": string("Search in titles and URLs."),
            "limit": ["type": "integer", "description": "1–200 results."], "offset": ["type": "integer", "description": "Results to skip."],
            "tool": string("WebMCP tool ID from webmcp-list."), "args": ["type": "object", "description": "WebMCP tool arguments."],
            // Noodle verifies membership and does the posting; this extension only supplies the card.
            "conversation": ["type": "string", "format": "noodle-conversation", "description": "Conversation you participate in."],
            "message": string("Message to send with the card. Defaults to the page title."),
            "file": file("read", "UTF-8 script in your workspace, instead of --text."),
            "args-file": file("read", "UTF-8 JSON arguments in your workspace, instead of --args."),
            "source": file("read", "Workspace file to upload."), "output": file("write", "New workspace file to create.")]
        let names: [String]
        switch operation {
        case .webMCPList: names = ["frame"]
        case .webMCPCall: names = ["tool", "args", "args-file", "frame"]
        case .history, .bookmarks: names = ["query", "limit", "offset"]
        case .bookmarkAdd: names = ["url", "title"]
        case .bookmarkUpdate: names = ["bookmark", "url", "title"]
        case .bookmarkRemove: names = ["bookmark"]
        case .open, .navigate: names = ["url"]
        case .inspect: names = ["frame"]
        case .eval: names = ["text", "file", "frame"]
        case .click: names = ["target", "x", "y", "frame", "count"]
        case .move, .scroll: names = ["target", "x", "y", "frame"]
        case .fill: names = ["target", "text", "frame"]
        case .key: names = ["text"]
        case .screenshot: names = ["output"]
        case .upload: names = ["source", "target", "frame"]
        case .download: names = ["download", "output"]
        case .dialog: names = ["accept", "text"]
        case .present: names = ["conversation", "message"]
        default: names = []
        }
        for name in names { properties[name] = options[name] }
        if operation.isFileTransfer { required.append(operation == .upload ? "source" : "output") }
        if operation == .present { required.append("conversation") }
        var tool: [String: Any] = [
            "name": operation.rawValue, "description": BrowserToolGuidance.tool(operation),
            // The broker's limit sits above the socket's so a slow launch still gets its answer.
            "_meta": ["noodle/timeout": operation.timeout + 30],
            "inputSchema": ["type": "object", "properties": properties, "required": required]]
        if operation == .list { tool["_meta"] = ["noodle/timeout": operation.timeout + 30, "noodle/resource-list": ["kind": "browser", "path": "browsers"]] }
        if [.list, .status, .tabs, .inspect, .downloads, .history, .bookmarks, .webMCPList].contains(operation) {
            tool["annotations"] = ["readOnlyHint": true, "idempotentHint": true]
        }
        return tool
    }

    // MARK: Calls

    public func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
        do {
            guard let operation = BrowserOperation(rawValue: tool), Self.operations.contains(operation) else {
                throw BrowserError("Noodle Browser has no tool named \(tool).")
            }
            let options = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            var request = try Self.request(operation, options: options, files: files)
            try request.validate()
            let response: BrowserResponse
            if operation.isFileTransfer {
                // The staging location is chosen here, never taken from a bot's arguments.
                let id = UUID()
                request.transferID = id
                let payload = try BrowserTransferFiles.staging(root: try stagingRoot(), id: id, create: true)
                defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
                if operation == .upload {
                    guard let source = files.first(where: { $0.parameter == "source" }) else { throw BrowserError("Specify --source with a workspace file.") }
                    request.filename = ((options["source"] as? String ?? "") as NSString).lastPathComponent
                    let count = try Self.copy(from: source.handle.fileDescriptor, toNew: payload)
                    // Staging a large file takes time. Ask Noodle again before it is sent.
                    try await context.authorize()
                    response = try await transport(request).checked()
                    guard response.byteCount == count else { throw BrowserError("The browser did not confirm the complete upload.") }
                } else {
                    guard let output = files.first(where: { $0.parameter == "output" }) else { throw BrowserError("Specify --output with a new workspace file.") }
                    response = try await transport(request).checked()
                    guard let size = response.byteCount, size >= 0, size <= BrowserTransferFiles.limit else { throw BrowserError("Invalid transferred file size.") }
                    let source = try BrowserTransferFiles.openSource(payload)
                    defer { Darwin.close(source) }
                    guard try BrowserTransferFiles.copy(source: source, destination: output.handle.fileDescriptor) == size else {
                        throw BrowserError("The transferred file is incomplete.")
                    }
                }
            } else {
                response = try await transport(request).checked()
            }
            if operation == .present { return try Self.card(response, request: request, message: options["message"] as? String) }
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any] ?? [:]
            var failed = false
            // Page scripts and WebMCP answer in JSON; hand bots the value, not a string to parse again.
            if [.inspect, .eval, .webMCPList, .webMCPCall].contains(operation), let raw = object.removeValue(forKey: "text") as? String {
                let value = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
                object["value"] = value
                // A website tool's own failure fails the call but keeps its structured details.
                failed = operation == .webMCPCall && (value as? [String: Any])?["status"] as? String == "error"
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "structuredContent": object, "isError": failed], options: [.sortedKeys])
        } catch {
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true], options: [.sortedKeys])
        }
    }

    private static func request(_ operation: BrowserOperation, options: [String: Any], files: [ToolFile]) throws -> BrowserRequest {
        func uuid(_ name: String) throws -> UUID? {
            guard let value = options[name] else { return nil }
            guard let id = (value as? String).flatMap(UUID.init(uuidString:)) else { throw BrowserError("Invalid UUID for --\(name).") }
            return id
        }
        func text(from name: String, what: String) throws -> String? {
            guard let file = files.first(where: { $0.parameter == name }) else { return nil }
            guard let data = try file.handle.read(upToCount: 1_048_577), data.count <= 1_048_576, let value = String(data: data, encoding: .utf8) else {
                throw BrowserError("\(what) must be UTF-8 and at most 1 MiB.")
            }
            return value
        }
        var request = try BrowserRequest(operation, browserID: uuid("browser"), tabID: uuid("tab"))
        request.url = options["url"] as? String; request.target = options["target"] as? String; request.frame = options["frame"] as? String
        request.text = options["text"] as? String
        request.x = (options["x"] as? NSNumber)?.doubleValue; request.y = (options["y"] as? NSNumber)?.doubleValue
        request.clickCount = options["count"] as? Int
        request.fileID = try uuid("download"); request.bookmarkID = try uuid("bookmark")
        request.title = options["title"] as? String; request.query = options["query"] as? String
        request.limit = options["limit"] as? Int; request.offset = options["offset"] as? Int
        request.toolID = options["tool"] as? String; request.accept = options["accept"] as? Bool
        if let script = try text(from: "file", what: "The script") {
            guard request.text == nil else { throw BrowserError("Use --file or --text, not both.") }
            request.text = script
        }
        if operation == .webMCPCall {
            let supplied = options["args"]
            guard supplied == nil || supplied is [String: Any] else { throw BrowserError("--args must be a JSON object.") }
            request.arguments = try (supplied as? [String: Any]).map {
                String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
            } ?? "{}"
            if let json = try text(from: "args-file", what: "Arguments") {
                guard supplied == nil else { throw BrowserError("Use --args or --args-file, not both.") }
                request.arguments = json
            }
        }
        return request
    }

    /// The page card for Noodle to post. It must describe exactly the browser and tab the
    /// broker authorized, and it never carries the browser's private description.
    private static func card(_ response: BrowserResponse, request: BrowserRequest, message: String?) throws -> Data {
        guard var reference = response.reference, reference.browser.id == request.browserID, reference.tabID == request.tabID else {
            throw BrowserError("The browser returned a different page reference.")
        }
        reference.browser.description = nil
        try reference.validate()
        let name = String(reference.title.prefix(120)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        let filename = name.isEmpty || name == "." || name == ".." ? "Browser Page" : name
        let post: [String: Any] = ["message": message ?? reference.title,
            "attachment": ["filename": filename, "mediaType": BrowserReference.mediaType, "data": try JSONEncoder().encode(reference).base64EncodedString()]]
        let structured: [String: Any] = ["tabID": reference.tabID.uuidString]
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "Presented."]], "structuredContent": structured,
                                                           "isError": false, "_meta": ["noodle/post": post]], options: [.sortedKeys])
    }

    private static func copy(from source: Int32, toNew url: URL) throws -> Int64 {
        let destination = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw BrowserError("Cannot stage the upload.") }
        defer { Darwin.close(destination) }
        return try BrowserTransferFiles.copy(source: source, destination: destination)
    }
}
