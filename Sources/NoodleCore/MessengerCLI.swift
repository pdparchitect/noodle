import Foundation
import UniformTypeIdentifiers

public struct MessengerCommandResult: Codable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum MessengerCLI {
    public static func shouldHandle(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let executable = arguments.first else { return false }
        return URL(fileURLWithPath: executable).lastPathComponent == "messenger" ||
            arguments.dropFirst().first == "messenger"
    }

    public static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MessengerCommandResult {
        do {
            let invocation = try Invocation(arguments: arguments, environment: environment)
            switch invocation.action {
            case .help: return MessengerCommandResult(exitCode: 0, standardOutput: help + "\n")
            case .listEffects: return .json(ConversationEffectKind.allCases.map(\.rawValue))
            default: return try MessengerBridgeClient.request(invocation.action, workspace: invocation.workspace)
            }
        } catch {
            return MessengerCommandResult(
                exitCode: 2,
                standardError: "messenger: \(error.localizedDescription)\n\n\(help)\n"
            )
        }
    }

    /// Trusted in-process entry point for app operations and repository tests.
    /// The shipped CLI always uses the bot-bound bridge, without a disk fallback.
    public static func runDirect(arguments: [String], environment: [String: String] = [:]) -> MessengerCommandResult {
        do {
            let invocation = try Invocation(arguments: arguments, environment: environment)
            return perform(invocation.action, repository: WorkspaceRepository(rootURL: invocation.repositoryRoot),
                           agentID: invocation.agentID)
        } catch { return .init(exitCode: 2, standardError: "messenger: \(error.localizedDescription)\n") }
    }

    public static func perform(_ action: MessengerAction, repository: WorkspaceRepository, agentID: UUID,
                               brokered: Bool = false) -> MessengerCommandResult {
        do {
            switch action {
            case .listEffects:
                return .json(ConversationEffectKind.allCases.map(\.rawValue))

            case .effect(let conversationID, let kind, let requestID):
                let event = try repository.sendEffect(agentID: agentID,
                    conversationID: conversationID, kind: kind, requestID: requestID)
                return .json(MessengerEffectReceipt(effect: event))

            case .getLatest(let consumes, let includesInlineImages):
                var response = MessengerCommandResult.json([MessengerDelivery]())
                do {
                    let deliveries = try repository.latestMessages(for: agentID, consuming: consumes, preparing: { original in
                        let visible = try brokered ? project(original, repository: repository, agentID: agentID) : original
                        if includesInlineImages {
                            var includedIDs = Set<UUID>()
                            let images = original.flatMap(\.attachments).compactMap { attachment -> MessengerInlineImage? in
                                guard includedIDs.insert(attachment.id).inserted,
                                      let dataURL = try? repository.inlineImageDataURL(for: attachment) else { return nil }
                                return MessengerInlineImage(attachmentID: attachment.id,
                                    originalFilename: attachment.originalFilename, mediaType: attachment.mediaType, dataURL: dataURL)
                            }
                            response = .json(MessengerInboxPayload(deliveries: visible, images: images))
                        } else { response = .json(visible) }
                        if brokered, try JSONEncoder().encode(response).count > MessengerBridgeClient.maxResponseBytes {
                            throw HarnessSetupError("The inbox is too large. Read individual conversations with --list-messages; no inbox offsets were advanced.")
                        }
                    })
                    RuntimeDiagnostics.inboxRead(agentID: agentID, workspace: repository.directory(forAgentID: agentID),
                                                 count: deliveries.count, consuming: consumes)
                    return response
                } catch {
                    RuntimeDiagnostics.inboxRead(agentID: agentID, workspace: repository.directory(forAgentID: agentID),
                                                 count: nil, consuming: consumes)
                    throw error
                }

            case .listConversations:
                let conversations = try repository.loadConversations()
                    .filter { $0.participantIDs.contains(agentID) }
                return .json(conversations)

            case .listParticipants(let conversationID):
                return .json(try repository.participantRoster(
                    for: agentID,
                    conversationID: conversationID
                ))

            case .listMessages(let conversationID):
                let deliveries = try repository.latestMessages(
                    for: agentID, consuming: false, in: conversationID, includingRead: true
                )
                return .json(try brokered ? project(deliveries, repository: repository, agentID: agentID) : deliveries)

            case .react(let conversationID, let messageID, let emoji, let present):
                return .json(try repository.setReaction(
                    conversationID: conversationID, messageID: messageID,
                    author: .agent(agentID), emoji: emoji, present: present
                ))

            case .send(let conversationID, let body, let attachmentURLs):
                // Check membership before importing anything, including URLs.
                _ = try repository.participantRoster(for: agentID, conversationID: conversationID)
                var importedAttachments: [ConversationAttachment] = []
                do {
                    for sourceURL in attachmentURLs {
                        let mediaType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
                            ?? "application/octet-stream"
                        if brokered, sourceURL.isFileURL {
                            let workspace = repository.directory(forAgentID: agentID)
                            let relative = try ComputerWorkspaceFiles.relativePath(sourceURL.path, currentDirectory: workspace, workspace: workspace)
                            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-messenger-" + UUID().uuidString)
                            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                                   attributes: [.posixPermissions: 0o700])
                            defer { try? FileManager.default.removeItem(at: staging) }
                            let file = staging.appendingPathComponent(sourceURL.lastPathComponent)
                            _ = try ComputerWorkspaceFiles.upload(workspace: workspace, path: relative, to: file)
                            importedAttachments.append(try repository.importAttachment(from: file, into: conversationID, mediaType: mediaType))
                        } else {
                            importedAttachments.append(try repository.importAttachment(from: sourceURL, into: conversationID, mediaType: mediaType))
                        }
                    }
                    let message = try repository.sendAgentMessage(
                        agentID: agentID,
                        conversationID: conversationID,
                        body: body,
                        attachmentIDs: importedAttachments.map(\.id)
                    )
                    return .json(message)
                } catch {
                    for attachment in importedAttachments {
                        try? repository.removeAttachment(attachment)
                    }
                    throw error
                }

            case .help:
                return MessengerCommandResult(exitCode: 0, standardOutput: help + "\n")
            }
        } catch { return .init(exitCode: 2, standardError: "messenger: \(error.localizedDescription)\n") }
    }

    private static func project(_ deliveries: [MessengerDelivery], repository: WorkspaceRepository,
                                agentID: UUID) throws -> [MessengerDelivery] {
        let workspace = repository.directory(forAgentID: agentID)
        var copies: [UUID: String] = [:]
        return try deliveries.map { original in
            var delivery = original
            delivery.attachments = try original.attachments.map { attachment in
                var item = attachment
                if let path = copies[item.id] { item.absolutePath = path; return item }
                let folder = try WorkspaceMailbox(workspace: workspace,
                    path: ".noodle/messenger-attachments/" + item.conversationID.uuidString.lowercased(), create: true)
                let source = repository.attachmentsDirectory(conversationID: item.conversationID).appendingPathComponent(item.storedFilename)
                guard source.standardizedFileURL.deletingLastPathComponent() == repository.attachmentsDirectory(conversationID: item.conversationID).standardizedFileURL,
                      source.resolvingSymlinksInPath() == source.standardizedFileURL else { throw WorkspaceError.invalidAttachment }
                try folder.copy(from: source, named: item.storedFilename)
                item.absolutePath = folder.url.appendingPathComponent(item.storedFilename).path
                copies[item.id] = item.absolutePath
                return item
            }
            return delivery
        }
    }

    private struct Invocation {
        let repositoryRoot: URL
        let agentID: UUID
        let workspace: URL
        let action: MessengerAction

        init(arguments: [String], environment: [String: String]) throws {
            guard let executable = arguments.first else { throw WorkspaceError.invalidAgentDirectory }
            var values = Array(arguments.dropFirst())
            if values.first == "messenger" { values.removeFirst() }

            let explicitDirectory = Self.option("--agent-directory", in: values).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let environmentDirectory = environment["NOODLE_WORKSPACE"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let resolvedWorkspace = try explicitDirectory ?? environmentDirectory ?? Self.agentDirectory(from: executable)
            let layout = try AgentStorageLayout.containing(resolvedWorkspace)
            workspace = layout.workspace
            guard let id = UUID(uuidString: layout.package.lastPathComponent) else {
                throw WorkspaceError.invalidAgentDirectory
            }
            let agentsDirectory = layout.package.deletingLastPathComponent()
            repositoryRoot = agentsDirectory.deletingLastPathComponent()
            agentID = id

            let command: MessengerCommandKind
            if values.contains("-h") || values.isEmpty {
                command = .help
            } else if let matched = MessengerCommandKind.allCases.first(where: { values.contains($0.rawValue) }) {
                command = matched
            } else {
                throw MessengerCLIError.invalidArguments
            }

            switch command {
            case .help:
                action = .help
            case .effect:
                let options = try Self.effectOptions(values)
                guard let rawConversation = options["--conversation"],
                      let conversationID = UUID(uuidString: rawConversation),
                      let kind = options["--effect"] else { throw MessengerCLIError.invalidArguments }
                let requestID: UUID
                if let rawID = options["--request-id"] {
                    guard let id = UUID(uuidString: rawID) else { throw MessengerCLIError.invalidArguments }
                    requestID = id
                } else { requestID = UUID() }
                action = .effect(conversationID: conversationID, kind: kind, requestID: requestID)
            case .listEffects:
                var rest = values
                rest.removeAll { $0 == "--list-effects" }
                guard rest.isEmpty || (rest.count == 2 && rest[0] == "--agent-directory") else {
                    throw MessengerCLIError.invalidArguments
                }
                action = .listEffects
            case .getLatest:
                action = .getLatest(
                    consumes: !values.contains("--peek"),
                    includesInlineImages: values.contains("--inline-images")
                )
            case .listConversations:
                action = .listConversations
            case .listParticipants:
                guard let raw = Self.option("--conversation", in: values),
                      let id = UUID(uuidString: raw) else { throw MessengerCLIError.invalidArguments }
                action = .listParticipants(conversationID: id)
            case .listMessages:
                guard let raw = Self.option("--conversation", in: values),
                      let id = UUID(uuidString: raw) else { throw MessengerCLIError.invalidArguments }
                action = .listMessages(conversationID: id)
            case .react, .unreact:
                guard values.contains("--react") != values.contains("--unreact"),
                      let rawConversation = Self.option("--conversation", in: values),
                      let conversationID = UUID(uuidString: rawConversation),
                      let rawMessage = Self.option("--message", in: values),
                      let messageID = UUID(uuidString: rawMessage),
                      let emoji = Self.option("--emoji", in: values) else {
                    throw MessengerCLIError.invalidArguments
                }
                action = .react(conversationID: conversationID, messageID: messageID,
                                emoji: emoji, present: values.contains("--react"))
            case .send:
                guard let rawConversation = Self.option("--conversation", in: values),
                      let conversationID = UUID(uuidString: rawConversation) else {
                    throw MessengerCLIError.invalidArguments
                }
                let currentDirectory = URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true
                )
                let attachmentURLs = try Self.options("--attach", in: values).map {
                    try AttachmentSource.resolve($0, relativeTo: currentDirectory)
                }
                let suppliedBody = try Self.messageBody(in: values)
                let body: String
                if let suppliedBody,
                   !suppliedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    body = suppliedBody
                } else if !attachmentURLs.isEmpty {
                    body = "Sent \(attachmentURLs.count) attachment\(attachmentURLs.count == 1 ? "" : "s")"
                } else {
                    throw MessengerCLIError.invalidArguments
                }
                action = .send(
                    conversationID: conversationID,
                    body: body,
                    attachmentURLs: attachmentURLs
                )
            }
        }

        private static func agentDirectory(from executable: String) throws -> URL {
            let currentDirectory = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            let executableURL = URL(fileURLWithPath: executable, relativeTo: currentDirectory)
                .standardizedFileURL
            guard executableURL.lastPathComponent == "messenger" else {
                throw WorkspaceError.invalidAgentDirectory
            }
            return executableURL
                .deletingLastPathComponent() // messenger skill
                .deletingLastPathComponent() // skills
                .deletingLastPathComponent() // .agents
                .deletingLastPathComponent() // opaque agent workspace
        }

        private static func effectOptions(_ arguments: [String]) throws -> [String: String] {
            let allowed: Set<String> = ["--effect", "--conversation", "--request-id", "--agent-directory"]
            guard arguments.count.isMultiple(of: 2) else { throw MessengerCLIError.invalidArguments }
            var options: [String: String] = [:]
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let key = arguments[index]
                let value = arguments[index + 1]
                guard allowed.contains(key), options[key] == nil, !value.hasPrefix("--") else {
                    throw MessengerCLIError.invalidArguments
                }
                options[key] = value
            }
            return options
        }

        private static func option(_ name: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        private static func options(_ name: String, in arguments: [String]) throws -> [String] {
            var values: [String] = []
            for index in arguments.indices where arguments[index] == name {
                guard arguments.indices.contains(index + 1) else {
                    throw MessengerCLIError.invalidArguments
                }
                values.append(arguments[index + 1])
            }
            return values
        }

        private static func messageBody(in arguments: [String]) throws -> String? {
            if let encoded = option("--body-percent-encoded", in: arguments) {
                guard let body = encoded.removingPercentEncoding else {
                    throw MessengerCLIError.invalidArguments
                }
                return body
            }
            if let encoded = option("--body-base64", in: arguments) {
                guard let data = Data(base64Encoded: encoded),
                      let body = String(data: data, encoding: .utf8) else {
                    throw MessengerCLIError.invalidArguments
                }
                return body
            }
            return option("--body", in: arguments)
        }
    }

    private static var help: String { MessengerDocumentation.cliHelp }
}

private struct MessengerEffectReceipt: Encodable {
    let effect: ConversationEffect
    let status: String

    init(effect: ConversationEffect) {
        self.effect = effect
        status = effect.consumedAt != nil ? "consumed" : (effect.expiresAt <= Date() ? "expired" : "queued")
    }
}

private enum MessengerCLIError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        "The command arguments are incomplete or invalid."
    }
}

private extension MessengerCommandResult {
    static func json<Value: Encodable>(_ value: Value) -> MessengerCommandResult {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return MessengerCommandResult(
                exitCode: 0,
                standardOutput: String(decoding: data, as: UTF8.self) + "\n"
            )
        } catch {
            return MessengerCommandResult(exitCode: 1, standardError: "messenger: \(error)\n")
        }
    }
}

public enum MessengerAction: Codable, Sendable {
        case listEffects
        case effect(conversationID: UUID, kind: String, requestID: UUID)
        case getLatest(consumes: Bool, includesInlineImages: Bool)
        case listConversations
        case listParticipants(conversationID: UUID)
        case listMessages(conversationID: UUID)
        case react(conversationID: UUID, messageID: UUID, emoji: String, present: Bool)
        case send(conversationID: UUID, body: String, attachmentURLs: [URL])
        case help
    }
