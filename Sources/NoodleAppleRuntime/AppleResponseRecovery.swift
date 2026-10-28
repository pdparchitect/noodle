import Foundation
import FoundationModels
import NoodleCore

/// Continue the existing session, including its completed tool exchanges. Never
/// retry a thrown tool/provider error or submit the user's original task again.
@available(macOS 26, *)
enum AppleResponseRecovery {
    static let incompletePrompt = "Your last response reached its output limit. Continue from the recorded tool results, then give a complete concise final answer. Do not repeat completed actions. If blocked, state what remains unfinished and why."
    static let emptyPrompt = "Your last response contained no answer. Continue from the recorded tool results: take the next necessary action or give the final answer. Do not repeat completed actions. If blocked, explain the blocker."

    static let messengerPrompt = "You have not checked your messages. Run ./.agents/skills/messenger/messenger --get-latest once, then answer any message that needs a reply with --send, or finish without a reply if none does."

    static func respond(session: LanguageModelSession, prompt: Prompt, responseTokens: Int,
                        control: AppleTurnControl, allowsEmptyReply: Bool = false, checksMessenger: Bool = false,
                        onEvent: @escaping @Sendable (AppleActivityEvent) async -> Void = { _ in },
                        onActivity: @escaping @Sendable () -> Void = {}) async throws -> String {
        // Response snapshots can be buffered until a generation ends. The
        // native transcript also changes during reasoning and tool arguments.
        // Only observed changes refresh activity; the timer itself never does.
        let activity = Task {
            var previous = session.transcript
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                let current = session.transcript
                if current != previous {
                    previous = current
                    onActivity()
                }
            }
        }
        defer { activity.cancel() }
        // The macOS 26 SDK used by CI predates the samplingMode label.
        #if canImport(FoundationModels, _version: 2)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: responseTokens)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: responseTokens)
        #endif
        var next = prompt
        var attempt = 0
        var checkedMessenger = !checksMessenger
        var reminded = false
        while true {
            try Task.checkCancellation()
            onActivity()
            await onEvent(.status("Generating response"))
            let response = try await session.streamResponse(to: next,
                options: options).collect()
            try Task.checkCancellation()
            checkedMessenger = checkedMessenger || ranMessengerCheck(response.transcriptEntries)
            let incomplete = isIncomplete(response.transcriptEntries)
            let empty = response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !incomplete && (!empty || allowsEmptyReply) {
                if checkedMessenger { return response.content }
                // A final answer is private, so a Noodle event answered
                // without reading the inbox would lose the person's message.
                // Finishing without a reply is fine once the inbox was read.
                guard !reminded else { throw AppleMessengerNotChecked() }
                reminded = true
                await control.recover()
                await onEvent(.status("Reminding the model to check its messages"))
                next = Prompt(messengerPrompt)
                continue
            }
            guard attempt < 2 else {
                throw HarnessSetupError(incomplete
                    ? "The model repeatedly reached its output limit without finishing a reply."
                    : "The model returned an empty reply after two recovery attempts.")
            }
            attempt += 1
            await control.recover()
            await onEvent(.status(incomplete ? "Retrying after the model's output limit (\(attempt)/2)"
                : "Retrying an empty model reply (\(attempt)/2)"))
            next = Prompt(incomplete ? incompletePrompt : emptyPrompt)
        }
    }

    /// Every Noodle event asks the bot to check Messenger once.
    static func expectsMessengerCheck(_ prompt: String) -> Bool {
        AgentWakeReason.allCases.contains { prompt.hasPrefix("<noodle-event type=\"\($0.rawValue)\"") }
    }

    /// Reading the inbox, not replying, is required: an empty inbox or a
    /// group message for someone else correctly ends without a reply.
    static func ranMessengerCheck(_ entries: ArraySlice<Transcript.Entry>) -> Bool {
        entries.contains { entry in
            guard case .toolCalls(let calls) = entry else { return false }
            return calls.contains { call in
                guard call.toolName == "bash",
                      let command = try? call.arguments.value(String.self, forProperty: "command") else { return false }
                return command.contains("messenger")
                    && (command.contains("--get-latest") || command.contains("--list-messages"))
            }
        }
    }

    static func isRecoveryPrompt(_ prompt: Transcript.Prompt) -> Bool {
        let text = prompt.segments.compactMap { segment -> String? in
            if case .text(let text) = segment { return text.content }; return nil
        }.joined()
        return text == incompletePrompt || text == emptyPrompt || text == messengerPrompt
    }

    static func isIncomplete(_ entries: ArraySlice<Transcript.Entry>) -> Bool {
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) {
            // A prior tool round can be truncated yet followed by a valid
            // answer. Only the final response determines whether to recover.
            for entry in entries.reversed() {
                if case .response(let response) = entry {
                    return (try? response.metadata["incompleteOutput"]?.value(Bool.self)) == true
                }
            }
        }
        #endif
        return false
    }
}

@available(macOS 26, *)
actor AppleTurnControl {
    let maximumGenerations: Int
    let maximumToolCalls: Int
    private(set) var recovering = false
    var generations = 0
    var toolCalls = 0
    var seenCalls = Set<String>()
    var recentExchanges: [String] = []
    var initialized = false
    var finishing = false
    var initialPromptID: String?

    init(maximumGenerations: Int = 32, maximumToolCalls: Int = 32, resuming: Bool = false) {
        self.maximumGenerations = max(2, maximumGenerations)
        self.maximumToolCalls = max(1, maximumToolCalls)
        // A restarted helper must not spend another full reasoning attempt on
        // the same unfinished task before it can use its recovery settings.
        recovering = resuming
    }
    func recover() { recovering = true }
}

struct AppleMessengerNotChecked: Error, LocalizedError {
    var errorDescription: String? { "The model did not check its messages, even when reminded." }
}
