import ComputerBridge
import Darwin
import Foundation

/// The command-line tool's side of a call, for its commands and its MCP server alike: names the
/// computer, reads and writes the caller's files, and shapes the answer. Noodle Computer decides
/// what the caller may do.
public struct ComputerExternalClient: Sendable {
    public typealias Transport = @Sendable (ComputerRequest) async throws -> ComputerResponse
    let environment: [String: String]
    /// Where relative paths start.
    let directory: URL
    let stagingRoot: @Sendable () throws -> URL
    let transport: Transport

    public init(environment: [String: String], directory: URL, stagingRoot: @escaping @Sendable () throws -> URL, transport: @escaping Transport) {
        self.environment = environment; self.directory = directory; self.stagingRoot = stagingRoot; self.transport = transport
    }

    public static let instructions = """
        Noodle Computer runs Linux computers and this Mac's own Local Mac account. This app sees only computers it created or a \
        person lent it. Start with list; use templates and create to make one, or borrow to ask the person to lend one of theirs. \
        Pass computer as a name or ID; it may be left out when there is only one. start a stopped computer, open a terminal, then \
        write commands and read their output from the returned offset. upload and download move files between this Mac and the \
        computer. The person is asked before this app is first allowed in, before it creates a computer, and before it borrows one.
        """

    static func describe(_ operation: ComputerOperation) -> String {
        switch operation {
        case .list: "List the computers this app may use, with each ID, name, kind, state and description."
        case .templates: "List the kinds of computer create can make."
        case .create: "Create a computer from --template ID with --name and optional --description. The person is asked first; a new computer may download its image."
        case .borrow: "Ask the person to lend one of their computers. They choose which, or decline. Returns the computer."
        case .update: "Rename or describe a computer this app created, with --name and optional --description."
        case .delete: "Delete a computer this app created, with everything on it."
        case .start: "Start the computer and wait until it runs."
        case .terminalOpen: "Open a shell in the running computer. Returns its terminal ID."
        case .terminalRead: "Read the terminal's output from --offset (default 0). Returns text and the offset to read from next."
        case .terminalWrite: "Send --text followed by Enter, or exact --base64 bytes, to the terminal."
        case .terminalResize: "Resize the terminal to --columns 1–500 and --rows 1–200."
        case .terminalClose: "Close the terminal."
        case .fileUpload: "Copy the file at --source PATH on this Mac to the absolute --destination path in the computer."
        case .fileDownload: "Copy the absolute --source path in the computer to --destination PATH on this Mac, a new file."
        default: ""
        }
    }

    // MARK: Command line

    public static func parse(_ arguments: [String]) throws -> (ComputerOperation, [String: Any]) {
        guard let name = arguments.first, let operation = ComputerOperation.externalCases.first(where: { $0.command == name }) else {
            throw ComputerBridgeError("Unknown command \(arguments.first ?? ""). Run noodle-computer help.")
        }
        let allowed = Set(accepted(operation))
        var options: [String: Any] = [:]
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            guard flag.hasPrefix("--"), allowed.contains(String(flag.dropFirst(2))) else {
                throw ComputerBridgeError("\(name) does not take \(flag).")
            }
            guard let value = rest.popFirst() else { throw ComputerBridgeError("\(flag) needs a value.") }
            options[String(flag.dropFirst(2))] = value
        }
        return (operation, options)
    }

    static func accepted(_ operation: ComputerOperation) -> [String] {
        ([.list, .templates, .create, .borrow].contains(operation) ? [] : ["computer"]) + operation.options
    }

    public static var usage: String {
        "Usage: noodle-computer COMMAND [OPTIONS]\n       noodle-computer mcp\n\n" + instructions + "\n\n"
            + ComputerOperation.externalCases.map(entry).joined(separator: "\n")
            + "\n  mcp\n      Serve these commands as MCP tools over standard input and output.\n"
    }

    /// `COMMAND --help`: that command alone; nil for a command there is not.
    public static func usage(for name: String) -> String? {
        ComputerOperation.externalCases.first { $0.command == name }.map { "Usage: noodle-computer " + entry($0).dropFirst(2) + "\n" }
    }

    private static func entry(_ operation: ComputerOperation) -> String {
        "  \(operation.command) " + accepted(operation).map { "[--\($0) VALUE]" }.joined(separator: " ") + "\n      \(describe(operation))"
    }

    // MARK: MCP

    public static func tools() -> [[String: Any]] {
        let string: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let integer: (String) -> [String: Any] = { ["type": "integer", "description": $0] }
        return ComputerOperation.externalCases.map { operation in
            let upload = operation == .fileUpload
            let all: [String: [String: Any]] = [
                "computer": string("Computer name or ID from list. May be left out when this app has only one."),
                "terminal": string("Terminal ID from open."), "offset": integer("Byte offset to read from."),
                "text": string("Text to send, followed by Enter."), "base64": string("Exact bytes to send, base64-encoded."),
                "columns": integer("1–500."), "rows": integer("1–200."),
                "template": string("Template ID from templates."), "name": string("Computer name."), "description": string("What the computer is for."),
                "source": string(upload ? "Path of the file on this Mac." : "Absolute path in the computer."),
                "destination": string(upload ? "Absolute path in the computer." : "Path of a new file on this Mac.")]
            var required: [String] = []
            if [.terminalRead, .terminalWrite, .terminalResize, .terminalClose].contains(operation) { required.append("terminal") }
            if operation == .terminalResize { required += ["columns", "rows"] }
            if operation == .create { required += ["template", "name"] }
            if operation == .update { required.append("name") }
            if operation.isFileTransfer { required += ["source", "destination"] }
            var tool: [String: Any] = ["name": operation.command, "description": describe(operation),
                "inputSchema": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: accepted(operation).map { ($0, all[$0]!) }),
                                "required": required]]
            if [.list, .templates, .terminalRead].contains(operation) { tool["annotations"] = ["readOnlyHint": true] }
            if operation == .delete { tool["annotations"] = ["destructiveHint": true] }
            return tool
        }
    }

    // MARK: Calls

    public func run(_ operation: ComputerOperation, options: [String: Any]) async throws -> [String: Any] {
        guard ComputerOperation.externalCases.contains(operation) else { throw ComputerBridgeError("Unknown command \(operation.command).") }
        if let unknown = options.keys.first(where: { !Self.accepted(operation).contains($0) }) {
            throw ComputerBridgeError("\(operation.command) does not take \(unknown).")
        }
        var request = try self.request(operation, options: options)
        request.computerID = try await computer(for: operation, named: options["computer"])
        var result = try operation.isFileTransfer ? await transfer(request, options: options) : Self.object(try await transport(request).checked())
        // Terminal output is text; the raw bytes stay only when they are not UTF-8.
        if let encoded = result["data"] as? String, let bytes = Data(base64Encoded: encoded) {
            if let text = String(data: bytes, encoding: .utf8) { result["text"] = text; result["data"] = nil }
            else { result["text"] = String(decoding: bytes, as: UTF8.self) }
        }
        return result
    }

    private func computer(for operation: ComputerOperation, named value: Any?) async throws -> UUID? {
        guard ![.list, .templates, .create, .borrow].contains(operation) else { return nil }
        let name = (value as? String) ?? environment["NOODLE_COMPUTER"]
        if let name, let id = UUID(uuidString: name) { return id }
        let computers = try await transport(ComputerRequest(.list)).checked().computers ?? []
        if let name {
            let matches = computers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1 else {
                throw ComputerBridgeError(matches.isEmpty ? "No computer named \(name). Run list." : "Several computers are named \(name). Use an ID from list.")
            }
            return matches[0].id
        }
        guard computers.count == 1 else {
            if computers.isEmpty { throw ComputerBridgeError("This app has no computers yet. Use create, or borrow to ask for one.") }
            throw ComputerBridgeError("Choose a computer with --computer: " + computers.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ") + ".")
        }
        return computers[0].id
    }

    private func request(_ operation: ComputerOperation, options: [String: Any]) throws -> ComputerRequest {
        func text(_ name: String) -> String? { options[name].map { $0 as? String ?? "\($0)" } }
        func integer(_ name: String) throws -> Int? {
            guard let value = options[name] else { return nil }
            if let value = value as? NSNumber, let integer = Int(exactly: value.doubleValue) { return integer }
            guard let value = value as? String, let integer = Int(value) else { throw ComputerBridgeError("--\(name) must be a whole number.") }
            return integer
        }
        var request = ComputerRequest(operation)
        if let terminal = text("terminal") {
            guard let id = UUID(uuidString: terminal) else { throw ComputerBridgeError("Invalid ID for --terminal.") }
            request.terminalID = id
        }
        request.offset = try integer("offset").map { Int64($0) }
        request.columns = try integer("columns"); request.rows = try integer("rows")
        if operation == .terminalWrite {
            let typed = text("text"), base64 = text("base64")
            guard (typed != nil) != (base64 != nil) else { throw ComputerBridgeError("Use either --text or --base64.") }
            request.data = typed.map { Data(($0 + "\r").utf8) } ?? base64.flatMap { Data(base64Encoded: $0) }
            guard request.data != nil else { throw ComputerBridgeError("Invalid base64 input.") }
        }
        if [.create, .update].contains(operation) {
            request.computer = ComputerDraft(template: operation == .create ? text("template") : nil, name: text("name") ?? "", description: text("description"))
        }
        if operation.isFileTransfer { request.path = text(operation == .fileUpload ? "destination" : "source") }
        return request
    }

    private func url(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
    }

    private func transfer(_ input: ComputerRequest, options: [String: Any]) async throws -> [String: Any] {
        var request = input
        let id = UUID()
        request.transferID = id
        let payload = try ComputerTransferFiles.staging(root: try stagingRoot(), id: id, create: true)
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        let upload = request.operation == .fileUpload
        guard let path = options[upload ? "source" : "destination"] as? String else { throw ComputerBridgeError("Specify --source and --destination.") }
        let local = url(path)
        let response: ComputerResponse
        if upload {
            let source = try ComputerTransferFiles.openSource(local)
            defer { Darwin.close(source) }
            let destination = Darwin.open(payload.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destination >= 0 else { throw ComputerBridgeError("Cannot stage the upload.") }
            let count: Int64
            do { defer { Darwin.close(destination) }; count = try ComputerTransferFiles.copy(source: source, destination: destination) }
            response = try await transport(request).checked()
            guard response.byteCount == count else { throw ComputerBridgeError("The computer did not confirm the complete upload. Check the file before retrying.") }
        } else {
            guard !FileManager.default.fileExists(atPath: local.path) else { throw ComputerBridgeError("\(local.path) already exists.") }
            response = try await transport(request).checked()
            guard let size = response.byteCount, size >= 0, size <= ComputerTransferFiles.limit else { throw ComputerBridgeError("The computer returned an invalid download size.") }
            let source = try ComputerTransferFiles.openSource(payload)
            defer { Darwin.close(source) }
            let destination = Darwin.open(local.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard destination >= 0 else { throw ComputerBridgeError("Cannot create \(local.path).") }
            defer { Darwin.close(destination) }
            guard try ComputerTransferFiles.copy(source: source, destination: destination) == size else {
                try? FileManager.default.removeItem(at: local)
                throw ComputerBridgeError("The downloaded file is incomplete.")
            }
        }
        var object = try Self.object(response)
        object["localPath"] = local.path
        return object
    }

    static func object(_ response: ComputerResponse) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any] ?? [:]
        object["capabilities"] = nil; object["version"] = nil
        return object
    }
}

/// The client's operations as MCP tools.
public struct ComputerMCPSource: MCPToolSource {
    let client: ComputerExternalClient
    public init(client: ComputerExternalClient) { self.client = client }
    public func tools() async throws -> Data { try JSONSerialization.data(withJSONObject: ComputerExternalClient.tools(), options: [.sortedKeys]) }
    public func call(_ name: String, arguments: Data) async -> Data {
        do {
            guard let operation = ComputerOperation.externalCases.first(where: { $0.command == name }) else {
                throw ComputerBridgeError("Noodle Computer has no tool named \(name).")
            }
            let options = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            let object = try await client.run(operation, options: options)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "structuredContent": object, "isError": false])
        } catch {
            return (try? JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])) ?? Data()
        }
    }
}
