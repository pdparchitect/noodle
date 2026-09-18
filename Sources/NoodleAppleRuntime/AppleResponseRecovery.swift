import Foundation
import FoundationModels
import NoodleCore

/// Continue the existing session, including its completed tool exchanges. Never
/// retry a thrown tool/provider error or submit the user's original task again.
@available(macOS 26, *)
enum AppleResponseRecovery {
    static let incompletePrompt = "Your last response reached its output limit. Continue from the recorded tool results, then give a complete concise final answer. Do not repeat completed actions. If blocked, state what remains unfinished and why."
    static let emptyPrompt = "Your last response contained no answer. Continue from the recorded tool results: take the next necessary action or give the final answer. Do not repeat completed actions. If blocked, explain the blocker."

    static func respond(session: LanguageModelSession, prompt: Prompt, responseTokens: Int,
                        control: AppleTurnControl, allowsEmptyReply: Bool = false,
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
        var next = prompt
        for attempt in 0...2 {
            try Task.checkCancellation()
            onActivity()
            await onEvent(.status("Generating response"))
            let response = try await session.streamResponse(to: next,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: responseTokens)).collect()
            try Task.checkCancellation()
            let incomplete = isIncomplete(response.transcriptEntries)
            let empty = response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !incomplete && (!empty || allowsEmptyReply) { return response.content }
            guard attempt < 2 else {
                throw HarnessSetupError(incomplete
                    ? "The model repeatedly reached its output limit without finishing a reply."
                    : "The model returned an empty reply after two recovery attempts.")
            }
            await control.recover()
            await onEvent(.status(incomplete ? "Retrying after the model's output limit (\(attempt + 1)/2)"
                : "Retrying an empty model reply (\(attempt + 1)/2)"))
            next = Prompt(incomplete ? incompletePrompt : emptyPrompt)
        }
        preconditionFailure("Bounded recovery must return or throw")
    }

    static func isRecoveryPrompt(_ prompt: Transcript.Prompt) -> Bool {
        let text = prompt.segments.compactMap { segment -> String? in
            if case .text(let text) = segment { return text.content }; return nil
        }.joined()
        return text == incompletePrompt || text == emptyPrompt
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
    private(set) var recovering = false
    var generations = 0
    var seenCalls = Set<String>()
    var recentExchanges: [String] = []
    var initialized = false
    var finishing = false
    var initialPromptID: String?

    init(maximumGenerations: Int = 32, resuming saved: AppleConversationSession? = nil) {
        self.maximumGenerations = max(2, maximumGenerations)
        // A restarted helper must not spend another full reasoning attempt on
        // the same unfinished task before it can use its recovery settings.
        recovering = saved.map { !$0.hasCompletedReply && !$0.transcript.isEmpty } ?? false
    }
    func recover() { recovering = true }
}
