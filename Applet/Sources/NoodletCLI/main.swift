import AppKit
import AppletBridge
import AppletCore
import Foundation

@main enum NoodletCLI {
    static func main() async {
        do { try await run() } catch {
            let data =
                (try? JSONEncoder().encode(AppletResponse(error: error.localizedDescription)))
                ?? Data()
            try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            exit(1)
        }
    }
    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, command != "--help" else {
            let help = appBundle()?.url(forResource: "NoodletCLIHelp", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            print(
                help
                    ?? "noodlet \(AppletOperation.allCases.map(\.rawValue).joined(separator: "|")) [--path PACKAGE] [--session UUID] [--output FILE] [--help]\nUse --path for open/build/validate, --session for running instances, --file for eval, --text for typing, --target or --x/--y for clicks, and --mode background|foreground|headless."
            )
            return
        }
        args.removeFirst()
        var name = command
        if name == "record", let sub = args.first {
            name += "-" + sub
            args.removeFirst()
        }
        guard let operation = AppletOperation(rawValue: name) else {
            throw AppletError("Unknown command. Use --help.")
        }
        let booleans: Set<String> = ["--follow", "--text-output"]
        let allowed: Set<String> = Set([
            "--path", "--session", "--output", "--file", "--text", "--target", "--mode", "--x",
            "--y", "--to-x", "--to-y", "--width", "--height", "--duration", "--offset",
            "--artifact", "--conversation", "--socket", "--team", "--id",
        ]).union(booleans)
        var flags: [String: String] = [:]
        while !args.isEmpty {
            let key = args.removeFirst()
            if !key.hasPrefix("--"), flags["--path"] == nil {
                flags["--path"] = key
                continue
            }
            guard allowed.contains(key), flags[key] == nil else {
                throw AppletError("Unknown or duplicate option: \(key)")
            }
            if booleans.contains(key) {
                flags[key] = "true"
            } else {
                guard !args.isEmpty else { throw AppletError("Missing value for \(key)") }
                flags[key] = args.removeFirst()
            }
        }
        func uuid(_ flag: String) throws -> UUID? {
            guard let s = flags[flag] else { return nil }
            guard let id = UUID(uuidString: s) else { throw AppletError("Invalid UUID: \(flag)") }
            return id
        }
        func number(_ flag: String) throws -> Double? {
            guard let s = flags[flag] else { return nil }
            guard let n = Double(s), n.isFinite else {
                throw AppletError("Invalid number: \(flag)")
            }
            return n
        }
        func integer(_ flag: String) throws -> Int? {
            guard let s = flags[flag] else { return nil }
            guard let n = Int(s) else { throw AppletError("Invalid integer: \(flag)") }
            return n
        }
        var request = AppletRequest(operation, sessionID: try uuid("--session"))
        if let value = flags["--id"] {
            request.noodletID = UUID(uuidString: value) ?? URL(string: value).flatMap(NoodletLink.id)
            guard request.noodletID != nil else { throw AppletError("Invalid noodlet ID or URL.") }
        }
        request.path = flags["--path"].map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        request.mode = flags["--mode"]
        request.text = flags["--text"]
        request.target = flags["--target"]
        request.x = try number("--x")
        request.y = try number("--y")
        request.toX = try number("--to-x")
        request.toY = try number("--to-y")
        request.width = try integer("--width")
        request.height = try integer("--height")
        request.duration = try number("--duration")
        request.offset = try integer("--offset")
        request.artifactID = try uuid("--artifact")
        if operation == .eval {
            if let file = flags["--file"] {
                request.text = try String(contentsOfFile: file, encoding: .utf8)
            } else if request.text == nil {
                request.text = String(
                    decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
        }
        if [.open, .build, .validate].contains(operation), let path = request.path {
            request.files = try NoodletPackage(url: URL(fileURLWithPath: path)).files()
        }
        try request.validate()
        let bridge = try workspaceBridge()
        let conversation = try uuid("--conversation")
        func call(_ input: AppletRequest) async throws -> AppletResponse {
            if let bridge {
                return try await mailbox(input, directory: bridge, conversation: conversation)
            }
            guard let bundle = appBundle() else {
                throw AppletError(
                    "Build/install Noodle Applet, or run the managed CLI inside a Noodle bot workspace."
                )
            }
            let socket =
                try flags["--socket"].map { URL(fileURLWithPath: $0) }
                ?? AppletConnection.socketURL(bundle: bundle)
            let team = try flags["--team"] ?? AppletConnection.signingTeam(bundle: bundle)
            do {
                return try await AppletConnection.call(input, socket: socket, team: team)
            } catch let error as AppletError where error.unavailable {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.arguments = ["--noodle-background"]
                guard
                    let provider = bundle.bundleIdentifier == AppletConnection.providerID
                        ? bundle.bundleURL
                        : NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: AppletConnection.providerID)
                else { throw AppletError("Install Noodle Applet first.") }
                _ = try await NSWorkspace.shared.openApplication(
                    at: provider, configuration: config)
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(250))
                    do {
                        return try await AppletConnection.call(input, socket: socket, team: team)
                    } catch let error as AppletError where error.unavailable { continue }
                }
                throw AppletError("Noodle Applet did not become ready.")
            }
        }
        var response = try await call(request)
        if response.error != nil {
            try emit(response, text: false)
            exit(1)
        }
        if let output = flags["--output"], let artifact = response.artifactID,
            operation != .recordStart
        {
            let url = URL(fileURLWithPath: output).standardizedFileURL
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw AppletError("Output already exists: \(output)")
            }
            let temp = url.deletingLastPathComponent().appendingPathComponent(
                ".\(UUID().uuidString).partial")
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: temp) }
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            var offset = 0
            repeat {
                var read = AppletRequest(.artifact, sessionID: response.sessionID)
                read.artifactID = artifact
                read.offset = offset
                let chunk = try await call(read).checked()
                guard let bytes = chunk.data, let next = chunk.offset, next >= offset,
                    !bytes.isEmpty || chunk.done == true
                else { throw AppletError("Invalid artifact transfer.") }
                try handle.write(contentsOf: bytes)
                offset = next
                if chunk.done == true { break }
            } while true
            try handle.close()
            try FileManager.default.moveItem(at: temp, to: url)
            response.path = url.path
        }
        if operation == .logs, flags["--follow"] != nil {
            while true {
                try emit(response, text: flags["--text-output"] != nil)
                if response.done == true { return }
                request.offset = response.offset
                request.id = UUID()
                try await Task.sleep(for: .milliseconds(300))
                response = try await call(request).checked()
            }
        }
        try emit(response, text: flags["--text-output"] != nil)
    }
    static func emit(_ response: AppletResponse, text: Bool) throws {
        if text {
            print(response.text ?? "", terminator: "")
        } else {
            try FileHandle.standardOutput.write(
                contentsOf: JSONEncoder().encode(response) + Data([10]))
        }
    }
    static func appBundle() -> Bundle? {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension == "app", let bundle = Bundle(url: url) { return bundle }
            url.deleteLastPathComponent()
        }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: AppletConnection.providerID
        ).flatMap(Bundle.init(url:))
    }
    static func workspaceBridge() throws -> URL? {
        var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while root.path != "/" {
            let candidate = root.appendingPathComponent(".noodle/applet-bridge")
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("session.json").path)
            {
                return candidate
            }
            root.deleteLastPathComponent()
        }
        return nil
    }
    static func mailbox(_ request: AppletRequest, directory: URL, conversation: UUID?) async throws
        -> AppletResponse
    {
        let session = try JSONDecoder().decode(
            AppletAgentSession.self,
            from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        guard kill(session.processID, 0) == 0 else { throw AppletError("Open Noodle first.") }
        let envelope = AppletAgentEnvelope(
            token: session.token, request: request, conversationID: conversation)
        let input = directory.appendingPathComponent(
            envelope.id.uuidString.lowercased() + ".request")
        let output = directory.appendingPathComponent(
            envelope.id.uuidString.lowercased() + ".response")
        try JSONEncoder().encode(envelope).write(to: input, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        let deadline = Date().addingTimeInterval(Double(request.operation.timeout + 10))
        while Date() < deadline {
            if let data = try? Data(contentsOf: output) {
                return try JSONDecoder().decode(AppletResponse.self, from: data)
            }
            guard kill(session.processID, 0) == 0 else {
                throw AppletError("Noodle stopped. Check the noodlet before retrying.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppletError("Request timed out. Inspect status before repeating a mutation.")
    }
}
