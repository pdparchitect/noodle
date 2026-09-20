import Darwin
import Foundation
import NoodleCore
import NoodleToolScripting

// `messenger tool PROVIDER --run FILE|-` and `--eval CODE` stream output and need a watchdog
// that works even while JavaScript loops forever, so the executable runs them itself.
if let invocation = try? MessengerCLI.toolInvocation() {
    do {
        if let script = try ToolCLI.script(invocation.arguments) { runScript(script, workspace: invocation.workspace) }
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data(("messenger tool: " + error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

let result = MessengerCLI.run()

if !result.standardOutput.isEmpty,
   let data = result.standardOutput.data(using: .utf8) {
    try? FileHandle.standardOutput.write(contentsOf: data)
}

if !result.standardError.isEmpty,
   let data = result.standardError.data(using: .utf8) {
    try? FileHandle.standardError.write(contentsOf: data)
}

exit(result.exitCode)

func runScript(_ script: ToolCLI.Script, workspace: URL) -> Never {
    let deadline = ProcessInfo.processInfo.systemUptime + Double(script.timeout)
    // A separate native queue can terminate even while JS loops forever or blocks writing
    // to a pipe. No private JavaScriptCore timeout API or JIT entitlement is needed.
    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Noodle.tool-script-deadline"))
    let timeoutMessage = Data("{\"error\":\"Tool script timed out after \(script.timeout) seconds. Verify any remote action before retrying.\"}\n".utf8)
    watchdog.setEventHandler {
        // Use an independent, nonblocking syscall: Foundation's file handle may already be
        // locked by a script blocked on a full output pipe.
        _ = fcntl(STDERR_FILENO, F_SETFL, fcntl(STDERR_FILENO, F_GETFL) | O_NONBLOCK)
        timeoutMessage.withUnsafeBytes { buffer in _ = Darwin.write(STDERR_FILENO, buffer.baseAddress, buffer.count) }
        _exit(1)
    }
    watchdog.schedule(deadline: .now() + Double(script.timeout))
    watchdog.resume()
    do {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let data: Data, sourceURL: URL
        switch script.mode {
        case .eval(let code): data = Data(code.utf8); sourceURL = URL(string: "messenger-tool:///eval.js")!
        case .run("-"):
            var input = Data()
            while input.count <= ToolScript.maxSourceBytes,
                  let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, ToolScript.maxSourceBytes + 1 - input.count)), !chunk.isEmpty {
                input.append(chunk)
            }
            data = input; sourceURL = URL(string: "messenger-tool:///stdin.js")!
        case .run(let path):
            let relative = try ComputerWorkspaceFiles.relativePath(path, currentDirectory: currentDirectory, workspace: workspace)
            let parts = relative.split(separator: "/").filter { $0 != "." }
            do {
                // The mailbox reader refuses symbolic and hard links, not only paths outside the workspace.
                let folder = try WorkspaceMailbox(workspace: workspace, path: parts.dropLast().joined(separator: "/"))
                data = try folder.read(String(parts.last!), limit: ToolScript.maxSourceBytes)
            } catch { throw ToolProviderError("Cannot read script. Use a regular UTF-8 workspace file without links, no larger than 1 MiB.") }
            sourceURL = workspace.appendingPathComponent(relative)
        }
        guard data.count <= ToolScript.maxSourceBytes, let source = String(data: data, encoding: .utf8) else {
            throw ToolProviderError("JavaScript source must be UTF-8 and no larger than 1 MiB.")
        }
        // Asked once, on the first call: "@path" is a file for a tool connection and plain text for every other tool.
        var kinds: [String: String]?
        try ToolScript.run(source, sourceURL: sourceURL, provider: script.provider, request: { request in
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ToolProviderError("Tool script timed out. Verify any remote action before retrying.") }
            switch request {
            case .providers:
                return try ToolBridgeClient.request(.providers, workspace: workspace, currentDirectory: currentDirectory)
            case .operation(let provider, let action, let tool, let arguments, let uri, let raw):
                if action == .call, kinds?[provider] == nil { kinds = try ToolCLI.kinds(workspace: workspace, currentDirectory: currentDirectory) }
                return try ToolCLI.operation(action, provider: provider, tool: tool, arguments: arguments, uri: uri, raw: raw,
                                             expandsFiles: kinds?[provider] == ToolProviderKind.connection.rawValue,
                                             workspace: workspace, currentDirectory: currentDirectory)
            }
        }, output: { data, diagnostic in
            try (diagnostic ? FileHandle.standardError : FileHandle.standardOutput).write(contentsOf: data)
        })
        exit(0)
    } catch {
        // Keep the deadline active while reporting a script failure, too. Actual newlines make
        // the source location and stack readable in a terminal.
        try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}
