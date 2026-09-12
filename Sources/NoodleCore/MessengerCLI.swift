import Foundation
import UniformTypeIdentifiers

public struct MessengerCommandResult: Sendable {
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
            let repository = WorkspaceRepository(rootURL: invocation.repositoryRoot)

            switch invocation.action {
            case .listEffects:
                return .json(ConversationEffectKind.allCases.map(\.rawValue))

            case .effect(let conversationID, let kind, let requestID):
                let event = try repository.sendEffect(agentID: invocation.agentID,
                    conversationID: conversationID, kind: kind, requestID: requestID)
                return .json(MessengerEffectReceipt(effect: event))

            case .getLatest(let consumes, let includesInlineImages):
                let deliveries: [MessengerDelivery]
                do {
                    deliveries = try repository.latestMessages(for: invocation.agentID, consuming: consumes)
                    RuntimeDiagnostics.inboxRead(agentID: invocation.agentID,
                        workspace: repository.directory(forAgentID: invocation.agentID),
                        count: deliveries.count, consuming: consumes)
                } catch {
                    RuntimeDiagnostics.inboxRead(agentID: invocation.agentID,
                        workspace: repository.directory(forAgentID: invocation.agentID),
                        count: nil, consuming: consumes)
                    throw error
                }
                if includesInlineImages {
                    var includedIDs = Set<UUID>()
                    let images = deliveries
                        .flatMap(\.attachments)
                        .compactMap { attachment -> MessengerInlineImage? in
                            guard includedIDs.insert(attachment.id).inserted,
                                  let dataURL = try? repository.inlineImageDataURL(for: attachment)
                            else { return nil }
                            return MessengerInlineImage(
                                attachmentID: attachment.id,
                                originalFilename: attachment.originalFilename,
                                mediaType: attachment.mediaType,
                                dataURL: dataURL
                            )
                        }
                    return .json(MessengerInboxPayload(deliveries: deliveries, images: images))
                }
                return .json(deliveries)

            case .listConversations:
                let conversations = try repository.loadConversations()
                    .filter { $0.participantIDs.contains(invocation.agentID) }
                return .json(conversations)

            case .listParticipants(let conversationID):
                return .json(try repository.participantRoster(
                    for: invocation.agentID,
                    conversationID: conversationID
                ))

            case .listMessages(let conversationID):
                return .json(try repository.latestMessages(
                    for: invocation.agentID, consuming: false, in: conversationID, includingRead: true
                ))

            case .react(let conversationID, let messageID, let emoji, let present):
                return .json(try repository.setReaction(
                    conversationID: conversationID, messageID: messageID,
                    author: .agent(invocation.agentID), emoji: emoji, present: present
                ))

            case .send(let conversationID, let body, let attachmentURLs):
                var importedAttachments: [ConversationAttachment] = []
                do {
                    for sourceURL in attachmentURLs {
                        let mediaType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
                            ?? "application/octet-stream"
                        importedAttachments.append(try repository.importAttachment(
                            from: sourceURL,
                            into: conversationID,
                            mediaType: mediaType
                        ))
                    }
                    let message = try repository.sendAgentMessage(
                        agentID: invocation.agentID,
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
        } catch {
            return MessengerCommandResult(
                exitCode: 2,
                standardError: "messenger: \(error.localizedDescription)\n\n\(help)\n"
            )
        }
    }

    private enum Action {
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

    private struct Invocation {
        let repositoryRoot: URL
        let agentID: UUID
        let action: Action

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
            let workspace = try explicitDirectory ?? environmentDirectory ?? Self.agentDirectory(from: executable)
            let layout = try AgentStorageLayout.containing(workspace)
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
