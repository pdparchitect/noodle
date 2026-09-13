import ComputerBridge
import Darwin
import Foundation
import NoodleCore

@main enum ComputerCLI {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first, command != "--help" else {
                print("computer list|start|open|read|write|resize|close|present|upload|download [--computer UUID] [--terminal UUID] [--text TEXT | --base64 DATA] [--offset N] [--columns N --rows N] [--conversation UUID --message TEXT --view terminal|web]")
                print("upload --computer UUID --source LOCAL_FILE --destination /guest/file")
                print("download --computer UUID --source /guest/file --destination LOCAL_FILE")
                print("Transfers: regular files up to 8 GiB; local files must be in this bot's workspace. Parent folders must exist; symlinks and overwrites are refused.")
                print("present --terminal SESSION_ID --conversation CHAT_ID: share this exact terminal (computer inferred).")
                print("present --computer COMPUTER_ID --conversation CHAT_ID: share its web display, or its only active terminal for a shell-only computer.")
                print("--view is a compatibility override; normally omit it. Multiple shell sessions require --terminal.")
                return
            }
            let operations: [String: ComputerOperation] = ["list": .list, "start": .start, "open": .terminalOpen,
                "read": .terminalRead, "write": .terminalWrite, "resize": .terminalResize,
                "close": .terminalClose, "present": .preview, "upload": .fileUpload, "download": .fileDownload]
            guard let operation = operations[command], args.count % 2 == 1 else { throw ComputerBridgeError("Invalid computer command. Use --help.") }
            var flags: [String: String] = [:]
            let allowed: [String: Set<String>] = ["list": [], "start": ["--computer"], "open": ["--computer"],
                "read": ["--computer", "--terminal", "--offset"], "write": ["--computer", "--terminal", "--text", "--base64"],
                "resize": ["--computer", "--terminal", "--columns", "--rows"], "close": ["--computer", "--terminal"],
                "present": ["--computer", "--terminal", "--conversation", "--message", "--view"],
                "upload": ["--computer", "--source", "--destination"], "download": ["--computer", "--source", "--destination"]]
            for index in stride(from: 1, to: args.count, by: 2) {
                guard allowed[command]!.contains(args[index]), flags[args[index]] == nil else { throw ComputerBridgeError("Unknown or repeated option.") }
                flags[args[index]] = args[index + 1]
            }
            func uuid(_ key: String) throws -> UUID? {
                guard let value = flags[key] else { return nil }
                guard let id = UUID(uuidString: value) else { throw ComputerBridgeError("Invalid UUID for \(key).") }
                return id
            }
            var input: Data?
            if command == "write" {
                guard (flags["--text"] != nil) != (flags["--base64"] != nil) else { throw ComputerBridgeError("Use either --text or --base64.") }
                input = flags["--text"].map { Data(($0 + "\r").utf8) } ?? flags["--base64"].flatMap { Data(base64Encoded: $0) }
                guard input != nil else { throw ComputerBridgeError("Invalid base64 input.") }
            }
            if let offset = flags["--offset"], Int64(offset) == nil { throw ComputerBridgeError("Invalid byte offset.") }
            var request = try ComputerRequest(operation, computerID: uuid("--computer"), terminalID: uuid("--terminal"),
                data: input, offset: flags["--offset"].flatMap(Int64.init), columns: flags["--columns"].flatMap(Int.init),
                rows: flags["--rows"].flatMap(Int.init))
            if operation.isFileTransfer {
                guard flags["--source"] != nil, flags["--destination"] != nil else {
                    throw ComputerBridgeError("Specify --source and --destination file paths.")
                }
                request.path = flags[operation == .fileUpload ? "--destination" : "--source"]
            }
            try request.validate()
            let conversation = try uuid("--conversation")
            if command == "present", conversation == nil { throw ComputerBridgeError("Specify the conversation for the computer card.") }
            if let view = flags["--view"], !["terminal", "web"].contains(view) { throw ComputerBridgeError("Use --view terminal or --view web.") }
            let context = try MCPInvocationContext.resolve(invocationPath: CommandLine.arguments[0],
                currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            let directory = try ComputerAgentSkill.bridge(workspace: context.workspace)
            let session = try JSONDecoder().decode(MCPBridgeSession.self, from: MCPBridgeFiles.read(directory.appendingPathComponent("session.json"), limit: 4096))
            guard kill(session.processID, 0) == 0 || errno == EPERM else { throw ComputerBridgeError("Open Noodle first.") }
            var envelope = ComputerAgentRequest(token: session.token, request: request, conversationID: conversation, message: flags["--message"], view: flags["--view"])
            if operation.isFileTransfer {
                envelope.localPath = try ComputerWorkspaceFiles.relativePath(flags[operation == .fileUpload ? "--source" : "--destination"]!,
                    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), workspace: context.workspace)
            }
            let stem = envelope.id.uuidString.lowercased()
            let inputURL = directory.appendingPathComponent(stem + ".request"), outputURL = directory.appendingPathComponent(stem + ".response")
            try MCPBridgeFiles.write(envelope, to: inputURL, workspace: context.workspace)
            defer { try? FileManager.default.removeItem(at: inputURL); try? FileManager.default.removeItem(at: outputURL) }
            let deadline = ProcessInfo.processInfo.systemUptime + Double(operation.timeout + 5)
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let data = try? MCPBridgeFiles.read(outputURL, limit: ComputerConnection.maxFrame) {
                    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    if let error = object["error"] as? String { throw ComputerBridgeError(error) }
                    if let path = envelope.localPath { object["localPath"] = path }
                    if let encoded = object["data"] as? String, let output = Data(base64Encoded: encoded) {
                        object["text"] = String(decoding: output, as: UTF8.self)
                    }
                    try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                    print(""); return
                }
                guard kill(session.processID, 0) == 0 || errno == EPERM else { throw ComputerBridgeError("Noodle stopped. Check the computer before retrying.") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw ComputerBridgeError("Computer request timed out. Check its state before retrying.")
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data(("computer: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
