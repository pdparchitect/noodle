import AppletBridge
import Darwin
import Foundation
import NoodleCore

/// Noodle Applet as tools. It runs inside Noodle and Noodle Hub because Noodle Applet trusts
/// only their signed identities to name the bot a request is for; an extension would need
/// that trust too. The broker has checked every call before it arrives here: the folder is
/// in the bot's workspace, the bot is in the conversation and a shared link was sent there.
public struct AppletToolProvider: ToolProvider {
    public typealias Transport = @Sendable (AppletRequest) async throws -> AppletResponse
    public let kind = ToolProviderKind.builtIn
    public let manifest = ToolProviderManifest(
        id: "applet", title: AppletBuildIdentity.current.appName, summary: AppletGuidance.summary,
        instructions: AppletGuidance.instructions(for: .current), activation: .whenGranted(AppletToolGrant.kind, id: AppletToolGrant.id))
    private let transport: Transport

    public init(transport: @escaping Transport) { self.transport = transport }

    // MARK: Tool list

    /// The package or session a command acts on. `link` and `conversation` reach a noodlet
    /// someone shared with a conversation the bot is in.
    private static let target = ["path", "id", "session", "link", "conversation"]
    private static let window = ["mode", "width", "height", "testClock"]

    static func options(_ operation: AppletOperation) -> [String] {
        switch operation {
        case .list: []
        case .validate, .build: ["path"]
        case .info: target
        case .open: ["path", "id", "link", "conversation"] + window
        case .restart: target + window
        case .logs: target + ["offset"]
        case .eval: target + ["text", "file"]
        case .click: target + ["target", "x", "y"]
        case .type: target + ["target", "text"]
        case .key: target + ["text"]
        case .scroll: target + ["target", "toX", "toY"]
        case .drag: target + ["x", "y", "toX", "toY"]
        case .screenshot, .recordStop: target + ["output"]
        case .recordStart: target + ["duration"]
        case .step: target + ["frames"]
        case .present: ["path", "id", "session", "conversation"]
        default: target
        }
    }

    private static let properties: [String: [String: Any]] = {
        let string: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let number: (String) -> [String: Any] = { ["type": "number", "description": $0] }
        let integer: (String) -> [String: Any] = { ["type": "integer", "description": $0] }
        return [
            "path": ["type": "string", "format": "noodle-file", "noodle/access": "folder", "description": "Package folder in your workspace."],
            "id": string("noodletID or noodlet:// URL of one of your own noodlets."),
            "session": string("sessionID from open."),
            "link": ["type": "string", "format": "noodle-conversation-link",
                     "description": "noodlet:// link sent in --conversation, for a noodlet someone shared."],
            "conversation": ["type": "string", "format": "noodle-conversation", "description": "Conversation you participate in."],
            "mode": ["type": "string", "enum": ["background", "headless"], "description": "Defaults to background."],
            "width": integer("Viewport width, 64–4096 points."), "height": integer("Viewport height, 64–4096 points."),
            "testClock": ["type": "boolean", "description": "Synthetic animation clock; needs --mode headless."],
            "offset": integer("Byte offset to read from."),
            "text": string("Text, key or JavaScript, as the command describes."),
            "file": ["type": "string", "format": "noodle-file", "description": "Workspace file with the JavaScript to run."],
            "target": string("CSS selector."),
            "x": number("Viewport points."), "y": number("Viewport points."),
            "toX": number("Viewport points."), "toY": number("Viewport points."),
            "output": ["type": "string", "format": "noodle-file", "noodle/access": "write", "description": "New workspace file to create."],
            "duration": number("Seconds, at most 60."),
            "frames": integer("1–600."),
        ]
    }()

    public func tools(context: ToolCallContext) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tools": AppletGuidance.toolOperations.map(Self.tool)], options: [.sortedKeys])
    }

    private static func tool(_ operation: AppletOperation) -> [String: Any] {
        let options = options(operation)
        var required: [String] = []
        if [.validate, .build].contains(operation) { required.append("path") }
        if operation == .present { required.append("conversation") }
        if [.screenshot, .recordStop].contains(operation) { required.append("output") }
        var tool: [String: Any] = [
            "name": operation.rawValue,
            "description": AppletGuidance.localized(AppletGuidance.operation(operation), for: .current),
            // A capture is read back in pieces after the command itself.
            "_meta": ["noodle/timeout": operation.timeout + (required.contains("output") ? 90 : 30)],
            "inputSchema": ["type": "object", "properties": properties.filter { options.contains($0.key) }, "required": required]]
        if [.list, .info, .status, .logs, .inspect].contains(operation) { tool["annotations"] = ["readOnlyHint": true, "idempotentHint": true] }
        return tool
    }

    // MARK: Calls

    public func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
        do {
            guard let operation = AppletGuidance.toolOperations.first(where: { $0.rawValue == tool }) else {
                throw AppletError("Noodle Applet has no tool named \(tool).")
            }
            let all = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            let options = all.filter { Self.options(operation).contains($0.key) }
            let request = try Self.request(operation, options: options, files: files, agent: context.agentID)
            try await context.authorize()
            let response = try await transport(request)
            if response.error != nil { return try Self.result(response, isError: true) }
            var object = try Self.object(response)
            if let artifact = response.artifactID, let output = files.first(where: { $0.parameter == "output" }) {
                try await download(artifact, session: response.sessionID, owner: request.owner, into: output.handle, authorize: context.authorize)
                object["output"] = options["output"] as? String
            }
            if operation == .present {
                guard let url = response.url, (try? NoodletLink.requireID(in: url)) != nil else {
                    throw AppletError("Update \(AppletBuildIdentity.current.appName) to share noodlet links.")
                }
                let post: [String: Any] = ["message": response.title ?? response.text ?? "Noodlet",
                    "attachment": ["filename": "Noodlet", "mediaType": NoodletLink.mediaType, "data": Data(url.absoluteString.utf8).base64EncodedString()]]
                return try JSONSerialization.data(withJSONObject: [
                    "content": [["type": "text", "text": "Presented."]], "structuredContent": object,
                    "isError": false, "_meta": ["noodle/post": post]], options: [.sortedKeys])
            }
            return try Self.result(object)
        } catch {
            return try Self.result(AppletResponse(error: error.localizedDescription, errorCode: (error as? AppletError)?.code), isError: true)
        }
    }

    /// The request as Noodle Applet reads it. The bot it is for is the one the broker identified,
    /// never an argument; a shared noodlet is reached through its link alone.
    static func request(_ operation: AppletOperation, options: [String: Any], files: [ToolFile], agent: UUID) throws -> AppletRequest {
        func uuid(_ name: String) throws -> UUID? {
            guard let value = options[name] else { return nil }
            guard let id = (value as? String).flatMap(UUID.init(uuidString:)) else { throw AppletError("Invalid UUID for --\(name).") }
            return id
        }
        var request = AppletRequest(operation, sessionID: try uuid("session"))
        request.owner = agent.uuidString.lowercased()
        if let value = options["id"] as? String {
            request.noodletID = try UUID(uuidString: value) ?? URL(string: value).map { try NoodletLink.requireID(in: $0) }
            guard request.noodletID != nil else { throw AppletError("Invalid noodlet ID or URL.") }
        }
        if let folder = files.first(where: { $0.parameter == "path" }) {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(folder.handle.fileDescriptor, F_GETPATH, &buffer) == 0 else { throw AppletError("Cannot read the package folder.") }
            request.path = String(cString: buffer)
        }
        if let value = options["link"] as? String {
            // The broker checked that the link was sent in the conversation; Noodle Applet keeps
            // a session named alongside it to that package.
            guard request.noodletID == nil, request.path == nil, let url = URL(string: value) else {
                throw AppletError("Use --link on its own, or with --session.")
            }
            request.noodletID = try NoodletLink.requireID(in: url)
            request.owner = "local"
        } else if options["conversation"] != nil, operation != .present {
            throw AppletError("Use --link with --conversation for a noodlet someone shared.", code: "session-unavailable")
        }
        request.mode = options["mode"] as? String
        request.testClock = options["testClock"] as? Bool
        request.width = options["width"] as? Int
        request.height = options["height"] as? Int
        request.offset = options["offset"] as? Int
        request.frames = options["frames"] as? Int
        request.target = options["target"] as? String
        request.text = options["text"] as? String
        request.x = (options["x"] as? NSNumber)?.doubleValue
        request.y = (options["y"] as? NSNumber)?.doubleValue
        request.toX = (options["toX"] as? NSNumber)?.doubleValue
        request.toY = (options["toY"] as? NSNumber)?.doubleValue
        request.duration = (options["duration"] as? NSNumber)?.doubleValue
        if let script = files.first(where: { $0.parameter == "file" }) {
            guard request.text == nil else { throw AppletError("Use either --text or --file.") }
            let data = try script.handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
                throw AppletError("--file must be UTF-8 text of at most 1 MiB.")
            }
            request.text = text
        }
        try request.keepOutOfSight()
        try request.validate()
        return request
    }

    /// Reads a capture in pieces into the file the broker created.
    private func download(_ artifact: UUID, session: UUID?, owner: String?, into handle: FileHandle,
                          authorize: @Sendable () async throws -> Void) async throws {
        var offset = 0
        while true {
            try await authorize()
            var read = AppletRequest(.artifact, sessionID: session)
            read.artifactID = artifact
            read.offset = offset
            read.owner = owner
            let chunk = try await transport(read).checked()
            guard let bytes = chunk.data, let next = chunk.offset, next == offset + bytes.count, !bytes.isEmpty || chunk.done == true else {
                throw AppletError("Invalid capture transfer.")
            }
            try handle.write(contentsOf: bytes)
            offset = next
            if chunk.done == true { return }
        }
    }

    /// The response as a bot reads it: no bookmarks, bytes or capture handles, which are Noodle's.
    private static func object(_ response: AppletResponse) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any] ?? [:]
        for key in ["previewBookmark", "data", "artifactID", "version", "features", "controls", "manifest", "stored"] { object[key] = nil }
        return object
    }

    private static func result(_ response: AppletResponse, isError: Bool) throws -> Data {
        try result(try object(response), isError: isError)
    }

    private static func result(_ object: [String: Any], isError: Bool = false) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "structuredContent": object,
                                                           "isError": isError], options: [.sortedKeys])
    }
}
