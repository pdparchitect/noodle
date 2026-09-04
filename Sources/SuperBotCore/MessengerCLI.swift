import Foundation

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
            case .getLatest(let consumes, let includesInlineImages):
                let deliveries = try repository.latestMessages(
                    for: invocation.agentID,
                    consuming: consumes
                )
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

            case .send(let conversationID, let body):
                let message = try repository.sendAgentMessage(
                    agentID: invocation.agentID,
                    conversationID: conversationID,
                    body: body
                )
                return .json(message)

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
        case getLatest(consumes: Bool, includesInlineImages: Bool)
        case listConversations
        case send(conversationID: UUID, body: String)
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
            let environmentDirectory = environment["SUPERBOT_WORKSPACE"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            let agentDirectory = try explicitDirectory ?? environmentDirectory ?? Self.agentDirectory(from: executable)
            guard let id = UUID(uuidString: agentDirectory.lastPathComponent) else {
                throw WorkspaceError.invalidAgentDirectory
            }
            let agentsDirectory = agentDirectory.deletingLastPathComponent()
            guard agentsDirectory.lastPathComponent == "Agents" else {
                throw WorkspaceError.invalidAgentDirectory
            }

            repositoryRoot = agentsDirectory.deletingLastPathComponent()
            agentID = id

            if values.contains("--help") || values.contains("-h") || values.isEmpty {
                action = .help
            } else if values.contains("--get-latest") {
                action = .getLatest(
                    consumes: !values.contains("--peek"),
                    includesInlineImages: values.contains("--inline-images")
                )
            } else if values.contains("--list-conversations") {
                action = .listConversations
            } else if values.contains("--send") {
                guard let rawConversation = Self.option("--conversation", in: values),
                      let conversationID = UUID(uuidString: rawConversation),
                      let body = try Self.messageBody(in: values) else {
                    throw MessengerCLIError.invalidArguments
                }
                action = .send(conversationID: conversationID, body: body)
            } else {
                throw MessengerCLIError.invalidArguments
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

        private static func option(_ name: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
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

    private static let help = """
    SuperBot Messenger

      messenger --get-latest [--peek] [--inline-images]
      messenger --list-conversations
      messenger --send --conversation <uuid> --body <text>
      messenger --send --conversation <uuid> --body-percent-encoded <percent-encoded-utf8>
      messenger --send --conversation <uuid> --body-base64 <utf8-base64>

    The command normally discovers the bot from its symlink path. For diagnostics, append
    --agent-directory <absolute-agent-workspace-path>.
    """
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
