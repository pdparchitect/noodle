import ComputerBridge
import Darwin
import Foundation
import NoodleCore

/// Noodle Computer as tools. Which computers a bot may use is decided and enforced by
/// Noodle's broker before a call arrives here; this provider only translates and forwards.
public struct ComputerToolProvider: ToolProvider {
    public typealias Transport = @Sendable (ComputerRequest) async throws -> ComputerResponse
    public let kind = ToolProviderKind.appExtension
    public let manifest = ToolProviderManifest(
        id: "computer", title: "Noodle Computer",
        summary: "Run commands, transfer files and share previews in the computers assigned to this bot.",
        instructions: ComputerToolGuidance.instructions, activation: .whenAssigned("computer"))
    private let transport: Transport
    private let stagingRoot: @Sendable () throws -> URL

    public init(stagingRoot: @escaping @Sendable () throws -> URL, transport: @escaping Transport) {
        self.stagingRoot = stagingRoot; self.transport = transport
    }

    // MARK: Tool list

    /// revoke, display and terminalResolve are for Noodle and the person using it, never bots.
    static let operations: [(name: String, operation: ComputerOperation, options: [String])] = [
        ("list", .list, []), ("start", .start, []), ("open", .terminalOpen, []),
        ("read", .terminalRead, ["terminal", "offset"]), ("write", .terminalWrite, ["terminal", "text", "base64"]),
        ("resize", .terminalResize, ["terminal", "columns", "rows"]), ("close", .terminalClose, ["terminal"]),
        ("present", .preview, ["terminal", "conversation", "message", "view"]),
        ("upload", .fileUpload, ["source", "destination"]), ("download", .fileDownload, ["source", "destination"])]

    public func tools(context: ToolCallContext) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tools": Self.operations.map(Self.tool)], options: [.sortedKeys])
    }

    private static func tool(_ entry: (name: String, operation: ComputerOperation, options: [String])) -> [String: Any] {
        let string: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let integer: (String) -> [String: Any] = { ["type": "integer", "description": $0] }
        var properties: [String: [String: Any]] = [:], required: [String] = []
        if entry.operation != .list {
            properties["computer"] = ["type": "string", "format": "noodle-resource", "noodle/kind": "computer", "description": "Assigned computer ID from list."]
            required.append("computer")
        }
        let upload = entry.operation == .fileUpload
        let options: [String: [String: Any]] = [
            "terminal": string("Terminal ID from open."), "offset": integer("Byte offset to read from."),
            "text": string("Text to send, followed by Enter."), "base64": string("Exact bytes to send, base64-encoded."),
            "columns": integer("1–500."), "rows": integer("1–200."),
            // Noodle verifies membership and does the posting; this extension only supplies the card.
            "conversation": ["type": "string", "format": "noodle-conversation", "description": "Conversation you participate in."],
            "message": string("Message to send with the card."), "view": ["type": "string", "enum": ["terminal", "web"], "description": "Normally omit."],
            "source": upload ? ["type": "string", "format": "noodle-file", "description": "Workspace file to upload."] : string("Absolute guest file path."),
            "destination": upload ? string("Absolute guest file path.")
                : ["type": "string", "format": "noodle-file", "noodle/access": "write", "description": "New workspace file to create."]]
        for name in entry.options { properties[name] = options[name] }
        if [.terminalRead, .terminalWrite, .terminalResize, .terminalClose].contains(entry.operation) { required.append("terminal") }
        if entry.operation == .preview { required.append("conversation") }
        if entry.operation.isFileTransfer { required += ["source", "destination"] }
        var tool: [String: Any] = [
            "name": entry.name, "description": ComputerToolGuidance.tool(entry.name),
            "_meta": ["noodle/timeout": entry.operation.timeout + 30],
            "inputSchema": ["type": "object", "properties": properties, "required": required]]
        if entry.operation == .list {
            tool["_meta"] = ["noodle/timeout": entry.operation.timeout + 30, "noodle/resource-list": ["kind": "computer", "path": "computers"]]
        }
        if [.list, .terminalRead].contains(entry.operation) { tool["annotations"] = ["readOnlyHint": true, "idempotentHint": entry.operation == .list] }
        return tool
    }

    // MARK: Calls

    public func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
        do {
            guard let entry = Self.operations.first(where: { $0.name == tool }) else { throw ComputerBridgeError("Noodle Computer has no tool named \(tool).") }
            let options = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            var request = try Self.request(entry.operation, options: options)
            // The owner of a terminal is the bot Noodle's broker identified, never an argument.
            request.agentID = context.agentID
            try request.validate()
            var object: [String: Any]
            switch entry.operation {
            case .fileUpload, .fileDownload: object = try await transfer(request, options: options, files: files, authorize: context.authorize)
            case .preview: return try await present(request, message: options["message"] as? String, authorize: context.authorize)
            default: object = try Self.object(try await perform(request, authorize: context.authorize))
            }
            // Terminal output is text for a bot; keep the raw bytes only when they are not UTF-8.
            if let encoded = object["data"] as? String, let bytes = Data(base64Encoded: encoded) {
                if let text = String(data: bytes, encoding: .utf8) { object["text"] = text; object["data"] = nil }
                else { object["text"] = String(decoding: bytes, as: UTF8.self) }
            }
            return try Self.result(object)
        } catch {
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true], options: [.sortedKeys])
        }
    }

    /// Checks compatibility before each action, including after the provider updates or
    /// restarts. The handshake is a local read and never replays the requested change.
    private func perform(_ request: ComputerRequest, authorize: @Sendable () async throws -> Void) async throws -> ComputerResponse {
        var handshake = ComputerRequest(.list)
        handshake.capabilitiesOnly = true
        let capabilities = try await transport(handshake).checked().capabilities
        try ComputerCapabilities.requireCompatible(capabilities)
        if request.operation.isFileTransfer { try ComputerCapabilities.requireFileTransfer(capabilities) }
        if request.operation == .preview { try ComputerCapabilities.requireDocumentPreview(capabilities) }
        // The handshake, and any staging before it, took time. Ask Noodle again before the
        // step that cannot be taken back.
        try await authorize()
        return try await transport(request).checked()
    }

    private func transfer(_ input: ComputerRequest, options: [String: Any], files: [ToolFile],
                          authorize: @Sendable () async throws -> Void) async throws -> [String: Any] {
        var request = input
        // The staging location is chosen here, never taken from a bot's arguments.
        let id = UUID()
        request.transferID = id
        let upload = request.operation == .fileUpload
        guard let file = files.first(where: { $0.parameter == (upload ? "source" : "destination") }) else {
            throw ComputerBridgeError("Specify --source and --destination file paths.")
        }
        // Reject a provider that cannot transfer before copying a potentially large file.
        var handshake = ComputerRequest(.list)
        handshake.capabilitiesOnly = true
        try ComputerCapabilities.requireFileTransfer(try await transport(handshake).checked().capabilities)
        let payload = try ComputerTransferFiles.staging(root: try stagingRoot(), id: id, create: true)
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        let response: ComputerResponse
        if upload {
            let destination = Darwin.open(payload.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destination >= 0 else { throw ComputerBridgeError("Cannot stage the upload.") }
            let count: Int64
            do { defer { Darwin.close(destination) }; count = try ComputerTransferFiles.copy(source: file.handle.fileDescriptor, destination: destination) }
            response = try await perform(request, authorize: authorize)
            guard response.byteCount == count else { throw ComputerBridgeError("The provider did not confirm the complete upload. Check the guest file before retrying.") }
        } else {
            response = try await perform(request, authorize: authorize)
            guard let size = response.byteCount, size >= 0, size <= ComputerTransferFiles.limit else { throw ComputerBridgeError("The provider returned an invalid download size.") }
            let source = Darwin.open(payload.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard source >= 0 else { throw ComputerBridgeError("The downloaded file is missing.") }
            defer { Darwin.close(source) }
            guard try ComputerTransferFiles.copy(source: source, destination: file.handle.fileDescriptor) == size else {
                throw ComputerBridgeError("The downloaded file is incomplete.")
            }
        }
        var object = try Self.object(response)
        object["localPath"] = options[upload ? "source" : "destination"] as? String
        return object
    }

    /// The card for Noodle to post. It describes exactly the computer the broker authorized.
    private func present(_ request: ComputerRequest, message: String?, authorize: @Sendable () async throws -> Void) async throws -> Data {
        guard let computer = try await perform(.init(.list), authorize: authorize).computers?.first(where: { $0.id == request.computerID }) else {
            throw ComputerBridgeError("This computer is unavailable.")
        }
        let response = try await perform(request, authorize: authorize)
        let text = String(decoding: response.data ?? Data(), as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let view = response.view ?? request.view ?? (request.terminalID != nil ? "terminal" : (computer.hasWebDisplay == true ? "web" : "terminal"))
        guard view != "web" || computer.hasWebDisplay == true else { throw ComputerBridgeError("This computer has no web display.") }
        let terminal = view == "terminal" ? (response.terminalID ?? request.terminalID) : nil
        guard view == "web" || terminal != nil else { throw ComputerBridgeError("The provider did not return a terminal session. Update Noodle Computer.") }
        let reference = ComputerReference(computer: computer, terminalID: terminal, terminalPreview: text, view: view,
                                          previewImage: view == "web" ? response.previewImage : nil)
        let name = computer.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        let filename = name.isEmpty || name == "." || name == ".." ? "Computer" : String(name.prefix(120))
        let post: [String: Any] = ["message": message ?? "Open \(computer.name)",
            "attachment": ["filename": filename, "mediaType": ComputerCard.mediaType, "data": try JSONEncoder().encode(reference).base64EncodedString()]]
        var structured: [String: Any] = ["view": view]
        structured["terminalID"] = terminal?.uuidString
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "Presented."]], "structuredContent": structured,
                                                           "isError": false, "_meta": ["noodle/post": post]], options: [.sortedKeys])
    }

    private static func request(_ operation: ComputerOperation, options: [String: Any]) throws -> ComputerRequest {
        func uuid(_ name: String) throws -> UUID? {
            guard let value = options[name] else { return nil }
            guard let id = (value as? String).flatMap(UUID.init(uuidString:)) else { throw ComputerBridgeError("Invalid UUID for --\(name).") }
            return id
        }
        var input: Data?
        if operation == .terminalWrite {
            let text = options["text"] as? String, base64 = options["base64"] as? String
            guard (text != nil) != (base64 != nil) else { throw ComputerBridgeError("Use either --text or --base64.") }
            input = text.map { Data(($0 + "\r").utf8) } ?? base64.flatMap { Data(base64Encoded: $0) }
            guard input != nil else { throw ComputerBridgeError("Invalid base64 input.") }
        }
        var request = try ComputerRequest(operation, computerID: uuid("computer"), terminalID: uuid("terminal"), data: input,
            offset: (options["offset"] as? NSNumber)?.int64Value, columns: options["columns"] as? Int, rows: options["rows"] as? Int)
        if operation == .preview { request.view = options["view"] as? String }
        if operation.isFileTransfer { request.path = options[operation == .fileUpload ? "destination" : "source"] as? String }
        return request
    }

    private static func object(_ response: ComputerResponse) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any] ?? [:]
        // Compatibility details are for Noodle, and display credentials are never for bots.
        object["capabilities"] = nil; object["display"] = nil; object["version"] = nil
        return object
    }

    private static func result(_ object: [String: Any]) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "structuredContent": object, "isError": false], options: [.sortedKeys])
    }
}
