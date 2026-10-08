import BrowserBridge
import Darwin
import Foundation

/// The command-line tool's side of a call, for its commands and its MCP server alike: names the
/// browser, reads and writes the caller's files, and shapes the answer. Noodle Browser decides
/// what the caller may do.
public struct BrowserExternalClient: Sendable {
    public typealias Transport = @Sendable (BrowserRequest) async throws -> BrowserResponse
    let environment: [String: String]
    /// Where relative paths start.
    let directory: URL
    let stagingRoot: @Sendable () throws -> URL
    let transport: Transport

    public init(environment: [String: String], directory: URL, stagingRoot: @escaping @Sendable () throws -> URL, transport: @escaping Transport) {
        self.environment = environment; self.directory = directory; self.stagingRoot = stagingRoot; self.transport = transport
    }

    public static let instructions = """
        Noodle Browser keeps persistent browser profiles, each with its own cookies and sign-ins, and drives them in the background. \
        This app sees only browsers it created or a person lent it. Start with list; use browser-create to make one, or browser-borrow \
        to ask the person to lend one of theirs. Pass browser as a name or ID; it may be left out when there is only one. Tab tools \
        default to the selected tab. File options are paths on this Mac. The person is asked before this app is first allowed in, and \
        before it borrows a browser.
        """

    static func describe(_ operation: BrowserOperation) -> String {
        switch operation {
        case .list: "List the browsers this app may use, with each ID, name and description."
        case .create: "Create a new browser profile with --name and optional --description. Returns its ID."
        case .borrow: "Ask the person to lend one of their browsers. They choose which, or decline. Returns the browser."
        case .update: "Rename or describe a browser this app created, with --name and optional --description."
        case .delete: "Delete a browser this app created, with its website data."
        case .status: "Read browser state, tabs, downloads, and pointer state and any dialog for --tab."
        case .tabs: "List tab IDs, titles, URLs, loading and error state."
        case .open: "Open a background tab, optionally with --url HTTP[S]_URL. Returns its tab ID."
        case .navigate: "Load --url HTTP[S]_URL in the tab."
        case .back: "Go back in the tab's history."
        case .forward: "Go forward in the tab's history."
        case .reload: "Reload the tab."
        case .close: "Close the tab; the browser's website data remains."
        case .inspect: "Read page text, elements and available frames. Optional --frame ID."
        case .eval: "Run JavaScript from --text BODY or --file PATH as an async function body; optional --frame ID. Returns its JSON value."
        case .webMCPList: "Discover the page's WebMCP tools, schemas and IDs; optional --frame ID."
        case .webMCPCall: "Call --tool ID from webmcp-list with --args JSON_OBJECT or --args-file PATH; optional --frame ID."
        case .click: "Move the pointer and click --target CSS_SELECTOR or --x X --y Y in viewport points; optional --frame ID and --count 1|2."
        case .move: "Move or hover the pointer over --target CSS_SELECTOR or --x X --y Y; optional --frame ID."
        case .mouseReset: "Clear hover and hide the tab's pointer."
        case .fill: "Set --target CSS_SELECTOR to --text VALUE and send input and change events; optional --frame ID."
        case .key: "Send --text Enter|Tab|Escape|Backspace|Space|ArrowLeft|ArrowRight|ArrowUp|ArrowDown to the focused element."
        case .scroll: "Scroll by --x DX --y DY (default 0, 600); optional --target CSS_SELECTOR and --frame ID."
        case .screenshot: "Save the viewport as a PNG at --output PATH, a new file."
        case .upload: "Attach the file at --source PATH to --target FILE_INPUT_SELECTOR; optional --frame ID."
        case .downloads: "List downloads with IDs and state."
        case .download: "Copy --download ID to --output PATH, a new file, once downloads says it is complete."
        case .dialog: "Answer a pending alert, confirm or prompt with --accept true|false and optional --text VALUE."
        case .history: "Search visits, newest first: optional --query TEXT, --limit 1–200, --offset N."
        case .bookmarks: "Search bookmarks: optional --query TEXT, --limit 1–200, --offset N."
        case .bookmarkAdd: "Save --url HTTP[S]_URL with optional --title TEXT."
        case .bookmarkUpdate: "Change --bookmark ID's --title and/or --url."
        case .bookmarkRemove: "Delete --bookmark ID."
        case .show: "Open the browser's window, for when the person needs to see it or sign in."
        case .present, .surfaceStream, .setOwner: ""
        }
    }

    // MARK: Command line

    /// `COMMAND --option value …`, the command being an operation's name.
    public static func parse(_ arguments: [String]) throws -> (BrowserOperation, [String: Any]) {
        guard let name = arguments.first, let operation = BrowserOperation(rawValue: name),
              BrowserOperation.externalCases.contains(operation) else {
            throw BrowserError("Unknown command \(arguments.first ?? ""). Run noodle-browser help.")
        }
        let allowed = Set(accepted(operation))
        var options: [String: Any] = [:]
        var rest = arguments.dropFirst()
        while let flag = rest.popFirst() {
            guard flag.hasPrefix("--"), allowed.contains(String(flag.dropFirst(2))) else {
                throw BrowserError("\(name) does not take \(flag).")
            }
            guard let value = rest.popFirst() else { throw BrowserError("\(flag) needs a value.") }
            options[String(flag.dropFirst(2))] = value
        }
        return (operation, options)
    }

    static func accepted(_ operation: BrowserOperation) -> [String] {
        ([.list, .create, .borrow].contains(operation) ? [] : ["browser"])
            + (operation.needsTab || operation == .status ? ["tab"] : []) + operation.options
    }

    public static var usage: String {
        "Usage: noodle-browser COMMAND [OPTIONS]\n       noodle-browser mcp\n\n" + instructions + "\n\n"
            + BrowserOperation.externalCases.map(entry).joined(separator: "\n")
            + "\n  mcp\n      Serve these commands as MCP tools over standard input and output.\n"
    }

    /// `COMMAND --help`: that command alone; nil for a command there is not.
    public static func usage(for name: String) -> String? {
        BrowserOperation(rawValue: name).flatMap { BrowserOperation.externalCases.contains($0) ? "Usage: noodle-browser " + entry($0).dropFirst(2) + "\n" : nil }
    }

    private static func entry(_ operation: BrowserOperation) -> String {
        "  \(operation.rawValue) " + accepted(operation).map { "[--\($0) VALUE]" }.joined(separator: " ") + "\n      \(describe(operation))"
    }

    // MARK: MCP

    public static func tools() -> [[String: Any]] {
        let string: (String) -> [String: Any] = { ["type": "string", "description": $0] }
        let all: [String: [String: Any]] = [
            "browser": string("Browser name or ID from list. May be left out when this app has only one."),
            "tab": string("Tab ID from open or tabs. Defaults to the selected tab."),
            "name": string("Browser name."), "description": string("What the browser is for."),
            "url": string("HTTP or HTTPS URL."), "target": string("CSS selector."), "frame": string("Frame ID from the latest inspect."),
            "text": string("Text, keys or an async JavaScript function body."), "x": ["type": "number", "description": "Viewport x in points."],
            "y": ["type": "number", "description": "Viewport y in points."], "count": ["type": "integer", "description": "1 or 2 clicks."],
            "download": string("Download ID from downloads."), "accept": ["type": "boolean", "description": "Accept or dismiss the dialog."],
            "bookmark": string("Bookmark ID from bookmarks."), "title": string("Bookmark title."), "query": string("Search in titles and URLs."),
            "limit": ["type": "integer", "description": "1–200 results."], "offset": ["type": "integer", "description": "Results to skip."],
            "tool": string("WebMCP tool ID from webmcp-list."), "args": ["type": "object", "description": "WebMCP tool arguments."],
            "file": string("Path of a UTF-8 script, instead of text."), "args-file": string("Path of a UTF-8 JSON arguments file, instead of args."),
            "source": string("Path of the file to upload."), "output": string("Path of a new file to create.")]
        return BrowserOperation.externalCases.map { operation in
            // What the browser always needs. Choices, such as a selector or coordinates, stay optional
            // and the browser says which is missing.
            let required: [String] = switch operation {
            case .create, .update: ["name"]
            case .upload: ["source", "target"]
            case .screenshot: ["output"]
            case .download: ["download", "output"]
            case .navigate, .bookmarkAdd: ["url"]
            case .webMCPCall: ["tool"]
            case .bookmarkUpdate, .bookmarkRemove: ["bookmark"]
            case .fill: ["target", "text"]
            case .key: ["text"]
            case .dialog: ["accept"]
            default: []
            }
            var tool: [String: Any] = ["name": operation.rawValue, "description": describe(operation),
                "inputSchema": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: accepted(operation).map { ($0, all[$0]!) }),
                                "required": required]]
            if [.list, .status, .tabs, .inspect, .downloads, .history, .bookmarks, .webMCPList].contains(operation) {
                tool["annotations"] = ["readOnlyHint": true, "idempotentHint": true]
            }
            if operation == .delete { tool["annotations"] = ["destructiveHint": true] }
            return tool
        }
    }

    // MARK: Calls

    /// Runs one operation and answers with its result as JSON values.
    public func run(_ operation: BrowserOperation, options: [String: Any]) async throws -> [String: Any] {
        guard BrowserOperation.externalCases.contains(operation) else { throw BrowserError("Unknown command \(operation.rawValue).") }
        if let unknown = options.keys.first(where: { !Self.accepted(operation).contains($0) }) {
            throw BrowserError("\(operation.rawValue) does not take \(unknown).")
        }
        var request = try self.request(operation, options: options)
        request.browserID = try await browser(for: operation, named: options["browser"])
        var result: [String: Any]
        if operation.isFileTransfer {
            result = try await transfer(request, options: options)
        } else {
            result = try Self.object(try await transport(request).checked())
        }
        if [.inspect, .eval, .webMCPList, .webMCPCall].contains(operation), let raw = result.removeValue(forKey: "text") as? String {
            result["value"] = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        }
        return result
    }

    private func browser(for operation: BrowserOperation, named value: Any?) async throws -> UUID? {
        guard ![.list, .create, .borrow].contains(operation) else { return nil }
        let name = (value as? String) ?? environment["NOODLE_BROWSER"]
        if let name, let id = UUID(uuidString: name) { return id }
        let browsers = try await transport(BrowserRequest(.list)).checked().browsers ?? []
        if let name {
            let matches = browsers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1 else {
                throw BrowserError(matches.isEmpty ? "No browser named \(name). Run list." : "Several browsers are named \(name). Use an ID from list.")
            }
            return matches[0].id
        }
        guard browsers.count == 1 else {
            if browsers.isEmpty { throw BrowserError("This app has no browsers yet. Use browser-create, or browser-borrow to ask for one.") }
            throw BrowserError("Choose a browser with --browser: " + browsers.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ") + ".")
        }
        return browsers[0].id
    }

    private func request(_ operation: BrowserOperation, options: [String: Any]) throws -> BrowserRequest {
        func text(_ name: String) -> String? { options[name].map { $0 as? String ?? "\($0)" } }
        func uuid(_ name: String) throws -> UUID? {
            guard let value = text(name) else { return nil }
            guard let id = UUID(uuidString: value) else { throw BrowserError("Invalid ID for --\(name).") }
            return id
        }
        func number(_ name: String) throws -> Double? {
            guard let value = options[name] else { return nil }
            if let value = value as? NSNumber { return value.doubleValue }
            guard let value = value as? String, let number = Double(value) else { throw BrowserError("--\(name) must be a number.") }
            return number
        }
        func integer(_ name: String) throws -> Int? {
            guard let value = try number(name) else { return nil }
            guard value == value.rounded(), let integer = Int(exactly: value) else { throw BrowserError("--\(name) must be a whole number.") }
            return integer
        }
        func file(_ name: String) throws -> String? {
            guard let path = text(name) else { return nil }
            let data = try Data(contentsOf: url(path))
            guard data.count <= 1_048_576, let value = String(data: data, encoding: .utf8) else { throw BrowserError("--\(name) must be UTF-8 and at most 1 MiB.") }
            return value
        }
        var request = BrowserRequest(operation, tabID: try uuid("tab"))
        request.url = text("url"); request.target = text("target"); request.frame = text("frame"); request.text = text("text")
        request.x = try number("x"); request.y = try number("y"); request.clickCount = try integer("count")
        request.fileID = try uuid("download"); request.bookmarkID = try uuid("bookmark")
        request.title = text("title"); request.query = text("query")
        request.limit = try integer("limit"); request.offset = try integer("offset"); request.toolID = text("tool")
        if let accept = options["accept"] {
            switch accept as? String ?? "\(accept)" {
            case "true", "1": request.accept = true
            case "false", "0": request.accept = false
            default: throw BrowserError("--accept must be true or false.")
            }
        }
        if let script = try file("file") {
            guard request.text == nil else { throw BrowserError("Use --file or --text, not both.") }
            request.text = script
        }
        if operation == .webMCPCall {
            let supplied = options["args"]
            if let object = supplied as? [String: Any] {
                request.arguments = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            } else if let json = supplied as? String {
                guard (try? JSONSerialization.jsonObject(with: Data(json.utf8))) is [String: Any] else { throw BrowserError("--args must be a JSON object.") }
                request.arguments = json
            } else if supplied != nil { throw BrowserError("--args must be a JSON object.") }
            if let json = try file("args-file") {
                guard supplied == nil else { throw BrowserError("Use --args or --args-file, not both.") }
                request.arguments = json
            }
            request.arguments = request.arguments ?? "{}"
        }
        if [.create, .update].contains(operation) {
            request.profile = BrowserDraft(name: text("name") ?? "", description: text("description"))
        }
        return request
    }

    private func url(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
    }

    private func transfer(_ input: BrowserRequest, options: [String: Any]) async throws -> [String: Any] {
        var request = input
        let id = UUID()
        request.transferID = id
        let payload = try BrowserTransferFiles.staging(root: try stagingRoot(), id: id, create: true)
        defer { try? FileManager.default.removeItem(at: payload.deletingLastPathComponent()) }
        if request.operation == .upload {
            guard let path = options["source"] as? String else { throw BrowserError("Specify --source with a file.") }
            let source = try BrowserTransferFiles.openSource(url(path))
            defer { Darwin.close(source) }
            let destination = Darwin.open(payload.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destination >= 0 else { throw BrowserError("Cannot stage the upload.") }
            defer { Darwin.close(destination) }
            let count = try BrowserTransferFiles.copy(source: source, destination: destination)
            request.filename = url(path).lastPathComponent
            let response = try await transport(request).checked()
            guard response.byteCount == count else { throw BrowserError("The browser did not confirm the complete upload.") }
            return try Self.object(response)
        }
        guard let path = options["output"] as? String else { throw BrowserError("Specify --output with a new file.") }
        let output = url(path)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw BrowserError("\(output.path) already exists.") }
        let response = try await transport(request).checked()
        guard let size = response.byteCount, size >= 0, size <= BrowserTransferFiles.limit else { throw BrowserError("Invalid transferred file size.") }
        let source = try BrowserTransferFiles.openSource(payload)
        defer { Darwin.close(source) }
        let destination = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard destination >= 0 else { throw BrowserError("Cannot create \(output.path).") }
        defer { Darwin.close(destination) }
        guard try BrowserTransferFiles.copy(source: source, destination: destination) == size else {
            try? FileManager.default.removeItem(at: output)
            throw BrowserError("The transferred file is incomplete.")
        }
        var object = try Self.object(response)
        object["output"] = output.path
        return object
    }

    static func object(_ response: BrowserResponse) throws -> [String: Any] {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any] ?? [:]
        object["version"] = nil
        return object
    }
}

/// The client's operations as MCP tools.
public struct BrowserMCPSource: MCPToolSource {
    let client: BrowserExternalClient
    public init(client: BrowserExternalClient) { self.client = client }
    public func tools() async throws -> Data { try JSONSerialization.data(withJSONObject: BrowserExternalClient.tools(), options: [.sortedKeys]) }
    public func call(_ name: String, arguments: Data) async -> Data {
        do {
            guard let operation = BrowserOperation(rawValue: name) else { throw BrowserError("Noodle Browser has no tool named \(name).") }
            let options = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
            let object = try await client.run(operation, options: options)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "structuredContent": object, "isError": false])
        } catch {
            return (try? JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])) ?? Data()
        }
    }
}
