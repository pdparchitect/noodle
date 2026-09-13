import Darwin
import Foundation
import NoodleCore

struct AppleConversationTurn: Sendable {
    struct Message: Sendable {
        let isAssistant: Bool
        let text: String
    }
    let conversationID: UUID
    let messageIDs: Set<UUID>
    let history: [Message]
    let prompt: String

    /// Give follow-ups immediate grounding without requiring the model to
    /// discover that it needs history. Old assistant mistakes are not facts.
    var chatPrompt: String {
        var budget = 2_048
        var messages: [String] = []
        for message in history.reversed() where !message.isAssistant {
            let text = message.text
            guard text.utf8.count <= budget else { break }
            messages.append(text)
            budget -= text.utf8.count
        }
        guard !messages.isEmpty else { return prompt }
        return "Earlier user messages, oldest first (quoted reference):\n"
            + messages.reversed().joined(separator: "\n\n")
            + "\n\nLatest user message to answer:\n" + prompt
    }

    /// A small model can mistake ordinary chat memory for a file operation.
    /// Require a concrete workspace reference in user requests before asking
    /// it to select filesystem tools. Assistant claims cannot grant tools.
    var hasWorkspaceReference: Bool {
        let userText = ([prompt] + history.suffix(4).filter { !$0.isAssistant }.map(\.text)).joined(separator: "\n")
        let pattern = #"(?i)\b(read_file|write_file|execute_command|files?|folders?|director(?:y|ies)|workspace|terminal|shell|commands?|scripts?|attachments?|filesystem|execute|run|bash|zsh|python|swift|javascript|pdf|spreadsheet)\b|(?:^|\s)(?:~?/|\.{1,2}/)\S+|\b[\w-]+\.[a-z0-9]{1,8}\b|(?m)^\s*(?:ls|pwd|cat|mkdir|touch|git|curl|find|rg)\b"#
        return userText.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Tool implementations are independent of the model API so bounds, cancellation,
/// and real filesystem behavior can be tested without making an inference request.
public actor AppleToolContext {
    public let workspace: URL
    private let messenger: MessengerClient
    private let agentID: UUID
    private var remainingCalls = 32
    private var inboxResult: String?
    private var inboxDeliveries: [MessengerDelivery] = []
    private let outputDirectory: URL
    private let pendingRepliesFile: URL
    private var pendingReplies: [String: Set<UUID>]
    private struct ReplyReceipt: Codable {
        let messageIDs: Set<UUID>
        let body: String
    }
    private let replyReceiptsFile: URL
    private var replyReceipts: [String: ReplyReceipt]

    public init(workspace: URL, messenger: MessengerClient? = nil) throws {
        let layout = try AgentStorageLayout.containing(workspace)
        self.workspace = layout.workspace
        guard let id = UUID(uuidString: layout.package.lastPathComponent) else { throw WorkspaceError.invalidAgentDirectory }
        agentID = id
        self.messenger = messenger ?? MessengerClient(workspace: layout.workspace)
        outputDirectory = layout.workspace.appendingPathComponent(".noodle/apple/outputs")
        pendingRepliesFile = layout.workspace.appendingPathComponent(".noodle/apple/pending-replies.json")
        if FileManager.default.fileExists(atPath: pendingRepliesFile.path) {
            pendingReplies = try JSONDecoder().decode([String: Set<UUID>].self, from: Data(contentsOf: pendingRepliesFile))
        } else { pendingReplies = [:] }
        replyReceiptsFile = layout.workspace.appendingPathComponent(".noodle/apple/reply-receipts.json")
        if FileManager.default.fileExists(atPath: replyReceiptsFile.path) {
            replyReceipts = try JSONDecoder().decode([String: ReplyReceipt].self, from: Data(contentsOf: replyReceiptsFile))
        } else { replyReceipts = [:] }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func beginCall() throws {
        try Task.checkCancellation()
        guard remainingCalls > 0 else { throw AppleToolLimit() }
        remainingCalls -= 1
    }

    private func url(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw HarnessSetupError("Provide a nonempty file path.") }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path)).standardizedFileURL
    }

    public func read(path: String, offset: Int = 0) throws -> String {
        try beginCall()
        guard offset >= 0 else { throw HarnessSetupError("The byte offset must be nonnegative.") }
        let file = try url(path)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch { throw HarnessSetupError("Could not read \(file.path): \(error.localizedDescription)") }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            return try present(FileManager.default.contentsOfDirectory(atPath: file.path).sorted().joined(separator: "\n"))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw HarnessSetupError("Read a regular file or directory.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: 3_072) ?? Data()
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let page = try textPage(bytes)
        let end = offset + page.count
        return page.text + "\n[bytes \(offset)..<\(end) of \(size)\(end < size ? "; call read_file with offset \(end) to continue" : "; end")]"
    }

    public func write(path: String, content: String) throws -> String {
        try beginCall()
        guard content.utf8.count <= 65_536 else { throw HarnessSetupError("Write at most 64 KiB per call.") }
        let destination = try url(path)
        // Atomic replacement of regular files. The OS sandbox remains the final
        // authority for both native tools and command descendants, including links.
        if FileManager.default.fileExists(atPath: destination.path) {
            let type = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
            guard type == .typeRegular else { throw HarnessSetupError("Write requires a regular file, not a directory or symbolic link.") }
        }
        try AtomicFile.write(Data(content.utf8), to: destination)
        return "Wrote \(content.utf8.count) bytes to \(destination.path)."
    }

    public func execute(command: String) async throws -> String {
        try beginCall()
        guard !command.isEmpty, command.utf8.count <= 16_384, !command.utf8.contains(0) else {
            throw HarnessSetupError("Provide a command of at most 16 KiB.")
        }
        let result = try await AppleCommand.run(command, workspace: workspace)
        return try present("Exit status: \(result.status)\n\(result.output)")
    }

    public func inbox() throws -> String {
        try beginCall()
        // A repeated tool call in one turn never consumes a second inbox batch.
        if let inboxResult { return inboxResult }
        let deliveries: [MessengerDelivery] = try messenger.call(.getLatest(consumes: true, includesInlineImages: false))
        inboxDeliveries = deliveries
        for delivery in deliveries where delivery.message.author == .user && delivery.reactionChange == nil {
            pendingReplies[delivery.conversation.id.uuidString.lowercased(), default: []].insert(delivery.message.id)
        }
        try savePendingReplies()
        RuntimeDiagnostics.inboxRead(agentID: agentID, workspace: workspace, count: deliveries.count, consuming: true)
        let result = try present(json(deliveries), alwaysSave: true)
        inboxResult = result
        return result
    }

    public func inboxPrompt() throws -> String {
        _ = try inbox()
        let messages = try inboxDeliveries.map { delivery in
            var text = "Conversation: \(delivery.conversation.id.uuidString.lowercased()) (\(delivery.conversation.kind.rawValue))\nFrom: \(delivery.sender.displayName) (\(delivery.sender.handle.rawValue))\nMessage: \(delivery.message.body)"
            if delivery.conversation.kind == .group { text += "\nParticipants: " + (try json(delivery.participants)) }
            if !delivery.attachments.isEmpty { text += "\nAttachments: " + (try json(delivery.attachments)) }
            if delivery.reactionChange != nil { text += "\nReaction details: " + (try json(delivery)) }
            return text
        }
        return try present(messages.isEmpty ? "No unread messages." : messages.joined(separator: "\n\n"))
    }

    func backgroundInboxPrompt() throws -> String? {
        _ = try inbox()
        inboxDeliveries.removeAll { $0.message.author == .user && $0.reactionChange == nil }
        inboxResult = try present(json(inboxDeliveries))
        guard !inboxDeliveries.isEmpty else { return nil }
        return try inboxPrompt()
    }

    public func history(conversation: String) throws -> String {
        try beginCall()
        let id = try conversationID(conversation)
        let messages: [MessengerDelivery] = try messenger.call(.listMessages(conversationID: id))
        return try present(json(messages))
    }

    /// The model needs the conversation's words, not repeated routing envelopes.
    /// Keep the full Messenger representation for event tools and the CLI.
    func conversationHistory(conversation: String, offset: Int = 0, includeAssistantReplies: Bool = true) throws -> String {
        try conversationHistoryPage(conversation: conversation, offset: offset, includeAssistantReplies: includeAssistantReplies).text
    }

    func conversationHistoryPage(conversation: String, offset: Int, includeAssistantReplies: Bool) throws -> AppleHistoryPage {
        try beginCall()
        let id = try conversationID(conversation)
        let messages: [MessengerDelivery] = try messenger.call(.listMessages(conversationID: id))
        let text = try messages.filter { includeAssistantReplies || $0.message.author == .user }.map { delivery in
            let role = delivery.message.author == .agent(agentID) ? "Assistant" : delivery.sender.displayName
            return "\(role): \(try conversationText(delivery))"
        }.joined(separator: "\n\n")
        let bytes = Data(text.utf8)
        guard offset >= 0, offset <= bytes.count else { throw HarnessSetupError("Use a history byte offset from 0 through \(bytes.count).") }
        let page = try textPage(Data(bytes.dropFirst(offset).prefix(3_072)))
        let end = offset + page.count
        return AppleHistoryPage(text: page.text + "\n[bytes \(offset)..<\(end) of \(bytes.count)\(end < bytes.count ? "; call conversation_history with offset \(end) to continue" : "; end")]",
                                nextOffset: end < bytes.count ? end : nil)
    }

    /// Rebuild ordinary chat from durable messages, preserving user/assistant
    /// roles. Each conversation gets its own bounded context and reply target.
    func conversationTurns() throws -> [AppleConversationTurn] {
        _ = try inbox()
        var turns: [AppleConversationTurn] = []
        for key in pendingReplies.keys.sorted() {
            let conversation = try conversationID(key)
            let deliveries: [MessengerDelivery] = try messenger.call(.listMessages(conversationID: conversation))
            // Reconcile only the exact reply prepared for these messages. An
            // unrelated reply may follow a new arrival while another turn runs.
            if let receipt = replyReceipts[key],
               let last = deliveries.lastIndex(where: { receipt.messageIDs.contains($0.message.id) }),
               deliveries.dropFirst(last + 1).contains(where: {
                   $0.message.author == .agent(agentID) && $0.message.body == receipt.body
               }) {
                pendingReplies[key]?.subtract(receipt.messageIDs)
                replyReceipts[key] = nil
            }
            let ids = pendingReplies[key, default: []]
            let indices = deliveries.indices.filter { ids.contains(deliveries[$0].message.id) }
            guard let first = indices.first, let last = indices.last else {
                pendingReplies[key] = nil
                continue
            }
            let pending = Array(deliveries[first...last])
            let prompt = try present(pending.map { try conversationText($0) }.joined(separator: "\n\n"))
            var budget = max(0, 6_000 - prompt.utf8.count)
            var history: [AppleConversationTurn.Message] = []
            for delivery in deliveries[..<first].suffix(16).reversed() {
                let text = try conversationText(delivery)
                guard text.utf8.count <= budget else { break }
                budget -= text.utf8.count
                history.append(.init(isAssistant: delivery.message.author == .agent(agentID), text: text))
            }
            turns.append(.init(conversationID: conversation, messageIDs: ids, history: history.reversed(), prompt: prompt))
        }
        try savePendingReplies()
        try saveReplyReceipts()
        return turns
    }

    func deliverReply(_ body: String, to turn: AppleConversationTurn) throws {
        try Task.checkCancellation()
        try prepareReply(body, to: turn)
        _ = try send(conversation: turn.conversationID.uuidString, body: body)
        let key = turn.conversationID.uuidString.lowercased()
        pendingReplies[key]?.subtract(turn.messageIDs)
        if pendingReplies[key]?.isEmpty == true { pendingReplies[key] = nil }
        try savePendingReplies()
        replyReceipts[key] = nil
        try saveReplyReceipts()
    }

    func prepareReply(_ body: String, to turn: AppleConversationTurn) throws {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw HarnessSetupError("The model returned an empty reply.") }
        replyReceipts[turn.conversationID.uuidString.lowercased()] = .init(messageIDs: turn.messageIDs, body: body)
        try saveReplyReceipts()
    }

    private func saveReplyReceipts() throws {
        try AtomicFile.write(JSONEncoder().encode(replyReceipts), to: replyReceiptsFile)
    }

    private func savePendingReplies() throws {
        try AtomicFile.write(JSONEncoder().encode(pendingReplies), to: pendingRepliesFile)
    }

    private func conversationText(_ delivery: MessengerDelivery) throws -> String {
        var text = delivery.message.body
        if delivery.conversation.kind == .group || delivery.message.author == .system {
            text = "\(delivery.sender.displayName): \(text)"
        }
        if !delivery.attachments.isEmpty { text += "\nAttachments: " + (try json(delivery.attachments)) }
        return text
    }

    public func conversations() throws -> String {
        try beginCall()
        let conversations: [BotConversation] = try messenger.call(.listConversations)
        return try present(json(conversations))
    }

    public func send(conversation: String, body: String) throws -> String {
        try beginCall()
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HarnessSetupError("A reply cannot be empty.") }
        let message: ChatMessage = try messenger.call(.send(conversationID: conversationID(conversation), body: body, attachmentURLs: []))
        return "Sent message \(message.id.uuidString.lowercased())."
    }

    private func conversationID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw HarnessSetupError("Use the exact conversation UUID from Messenger.") }
        return id
    }

    private func present(_ value: String, alwaysSave: Bool = false) throws -> String {
        let data = Data(value.utf8)
        guard alwaysSave || data.count > 3_072 else { return value }
        let file = outputDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).txt")
        try AtomicFile.write(data, to: file)
        if data.count <= 3_072 { return value }
        let page = try textPage(Data(data.prefix(3_072)))
        return page.text
            + "\n[Full result saved at \(file.path); \(data.count) bytes.\(data.count > page.count ? " Read remaining bytes with read_file offset \(page.count) before considering this result complete." : "")]"
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func textPage(_ bytes: Data) throws -> (text: String, count: Int) {
        if bytes.isEmpty { return ("", 0) }
        for removed in 0...min(3, bytes.count - 1) {
            let page = bytes.prefix(bytes.count - removed)
            if let text = String(data: page, encoding: .utf8) { return (text, page.count) }
        }
        throw HarnessSetupError("This is not UTF-8 text, or the offset splits a character. Use the next offset returned by read_file.")
    }
}

struct AppleToolLimit: LocalizedError {
    var errorDescription: String? { "Apple reached the 32-tool limit for this turn. Unfinished work is preserved; retry to continue." }
}

public enum AppleCommand {
    public struct Result: Sendable { public let status: Int32; public let output: String }

    /// Foundation starts a child process group. Track it so turn cancellation,
    /// timeouts, and SIGTERM on the harness also terminate command descendants.
    public static func run(_ command: String, workspace: URL, timeout: TimeInterval = 60) async throws -> Result {
        let job = CommandJob()
        return try await withTaskCancellationHandler {
            try await Task.detached { try job.run(command, workspace: workspace, timeout: timeout) }.value
        } onCancel: { job.cancel() }
    }

    public static func stopAll() { CommandRegistry.shared.stopAll() }
}

private final class CommandRegistry: @unchecked Sendable {
    static let shared = CommandRegistry()
    private let lock = NSLock()
    private var jobs: [UUID: CommandJob] = [:]
    func add(_ job: CommandJob, id: UUID) { lock.lock(); defer { lock.unlock() }; jobs[id] = job }
    func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; jobs[id] = nil }
    func stopAll() {
        lock.lock(); let active = Array(jobs.values); lock.unlock()
        active.forEach { $0.cancel() }
    }
}

private final class CommandJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pid: Int32?
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let pid { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
    }
    func run(_ command: String, workspace: URL, timeout: TimeInterval) throws -> AppleCommand.Result {
        let id = UUID()
        CommandRegistry.shared.add(self, id: id)
        defer { CommandRegistry.shared.remove(id) }
        let child = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", command]
        child.currentDirectoryURL = workspace
        child.environment = ["HOME": workspace.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                             "TMPDIR": workspace.appendingPathComponent(".noodle/tmp").path,
                             "NOODLE_WORKSPACE": workspace.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe; child.standardError = pipe
        child.terminationHandler = { _ in finished.signal() }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); pid = child.processIdentifier; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer {
            lock.lock()
            // Clean up background processes even after a successful shell exit.
            if let pid { kill(-pid, SIGKILL) }
            pid = nil
            lock.unlock()
            pipe.fileHandleForReading.closeFile()
        }
        pipe.fileHandleForWriting.closeFile()
        let capture = CommandOutput()
        DispatchQueue.global(qos: .utility).async {
            while let data = try? pipe.fileHandleForReading.read(upToCount: 16_384), !data.isEmpty {
                if !capture.append(data) { self.cancel(); break }
            }
            drained.signal()
        }
        if finished.wait(timeout: .now() + min(max(timeout, 0.1), 60)) != .success {
            cancel()
            _ = finished.wait(timeout: .now() + 2)
            throw HarnessSetupError("Command exceeded its time limit and was stopped.")
        }
        // A background process can retain the pipe after its shell has finished.
        kill(-child.processIdentifier, SIGKILL)
        _ = drained.wait(timeout: .now() + 2)
        if capture.overflow { throw HarnessSetupError("Command output exceeded 1 MiB and was stopped.") }
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        return .init(status: child.terminationStatus, output: capture.text)
    }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceeded = false
    func append(_ bytes: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if data.count + bytes.count > 1_048_576 { exceeded = true; return false }
        data.append(bytes); return true
    }
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
