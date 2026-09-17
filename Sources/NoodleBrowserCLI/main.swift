import BrowserBridge
import Darwin
import Foundation
import NoodleCore

@main enum BrowserCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, command != "--help" else { print(MessengerDocumentation.browserCLIHelp); return }
            guard let operation = BrowserOperation(rawValue: command), args.count % 2 == 1 else { throw BrowserError("Invalid command. Use --help.") }
            let common: Set<String> = operation == .list ? [] : ["--browser"]
            let tab: Set<String> = operation.needsTab || operation == .status ? ["--tab"] : []
            let specific: Set<String>
            switch operation {
            case .history, .bookmarks: specific = ["--query", "--limit", "--offset"]
            case .bookmarkAdd: specific = ["--url", "--title"]
            case .bookmarkUpdate: specific = ["--bookmark", "--url", "--title"]
            case .bookmarkRemove: specific = ["--bookmark"]
            case .open, .navigate: specific = ["--url"]
            case .inspect: specific = ["--frame"]
            case .eval: specific = ["--text", "--file", "--frame"]
            case .click, .scroll: specific = ["--target", "--x", "--y", "--frame"]
            case .fill: specific = ["--target", "--text", "--frame"]
            case .key: specific = ["--text"]
            case .screenshot: specific = ["--output"]
            case .upload: specific = ["--source", "--target", "--frame"]
            case .download: specific = ["--download", "--output"]
            case .dialog: specific = ["--accept", "--text"]
            case .present: specific = ["--conversation", "--message"]
            default: specific = []
            }
            let allowed = common.union(tab).union(specific)
            var flags: [String: String] = [:]
            for index in stride(from: 1, to: args.count, by: 2) {
                let key = args[index]
                guard allowed.contains(key), flags[key] == nil else { throw BrowserError("Unknown or repeated option: \(key)") }
                flags[key] = args[index + 1]
            }
            func uuid(_ key: String) throws -> UUID? {
                guard let value = flags[key] else { return nil }
                guard let id = UUID(uuidString: value) else { throw BrowserError("Invalid UUID for \(key).") }; return id
            }
            func number(_ key: String) throws -> Double? {
                guard let value = flags[key] else { return nil }
                guard let number = Double(value), number.isFinite else { throw BrowserError("Invalid number for \(key).") }; return number
            }
            func integer(_ key: String) throws -> Int? {
                guard let value = flags[key] else { return nil }
                guard let number = Int(value) else { throw BrowserError("Invalid integer for \(key).") }; return number
            }
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let context = try MCPInvocationContext.resolve(invocationPath: CommandLine.arguments[0], currentDirectory: cwd)
            var request = try BrowserRequest(operation, browserID: uuid("--browser"), tabID: uuid("--tab"))
            request.url = flags["--url"]; request.target = flags["--target"]; request.frame = flags["--frame"]
            request.text = flags["--text"]; request.x = try number("--x"); request.y = try number("--y")
            request.fileID = try uuid("--download")
            request.bookmarkID = try uuid("--bookmark"); request.title = flags["--title"]; request.query = flags["--query"]
            request.limit = try integer("--limit"); request.offset = try integer("--offset")
            if let file = flags["--file"] {
                guard request.text == nil else { throw BrowserError("Use --file or --text, not both.") }
                let path = try ComputerWorkspaceFiles.relativePath(file, currentDirectory: cwd, workspace: context.workspace)
                let data = try MCPBridgeFiles.read(context.workspace.appendingPathComponent(path), limit: 1_048_576, workspace: context.workspace)
                guard let source = String(data: data, encoding: .utf8) else { throw BrowserError("Script must be UTF-8.") }
                request.text = source
            }
            if let accept = flags["--accept"] {
                guard ["true", "false"].contains(accept) else { throw BrowserError("Use --accept true or false.") }
                request.accept = accept == "true"
            }
            try request.validate()
            var localPath: String?
            if operation.isFileTransfer {
                let key = operation == .upload ? "--source" : "--output"
                guard let path = flags[key] else { throw BrowserError("Specify \(key) WORKSPACE_FILE.") }
                localPath = try ComputerWorkspaceFiles.relativePath(path, currentDirectory: cwd, workspace: context.workspace)
            }
            let directory = try BrowserAgentSkill.bridge(workspace: context.workspace)
            let session = try JSONDecoder().decode(MCPBridgeSession.self, from: MCPBridgeFiles.read(directory.appendingPathComponent("session.json"), limit: 4096))
            guard kill(session.processID, 0) == 0 || errno == EPERM else { throw BrowserError("Open Noodle first.") }
            var envelope = BrowserAgentRequest(token: session.token, request: request, localPath: localPath)
            envelope.conversationID = try uuid("--conversation"); envelope.message = flags["--message"]
            if operation == .present, envelope.conversationID == nil { throw BrowserError("Specify --conversation UUID for the browser card.") }
            let stem = envelope.id.uuidString.lowercased()
            let input = directory.appendingPathComponent(stem + ".request"), output = directory.appendingPathComponent(stem + ".response")
            try MCPBridgeFiles.write(envelope, to: input, workspace: context.workspace)
            defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
            let deadline = ProcessInfo.processInfo.systemUptime + Double(operation.timeout + 5)
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let data = try? MCPBridgeFiles.read(output, limit: BrowserConnection.maxFrame, workspace: context.workspace) {
                    _ = try JSONDecoder().decode(BrowserResponse.self, from: data).checked()
                    var result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    if let path = localPath { result["localPath"] = path }
                    if [.inspect, .eval].contains(operation), let text = result.removeValue(forKey: "text") as? String {
                        result["value"] = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
                    }
                    try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
                    print(""); return
                }
                guard kill(session.processID, 0) == 0 || errno == EPERM else { throw BrowserError("Noodle stopped. Check browser state before retrying.") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw BrowserError("Browser request timed out. Check its state before retrying an action.")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data(("browser: " + error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
