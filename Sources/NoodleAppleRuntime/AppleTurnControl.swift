#if canImport(FoundationModels, _version: 2)
import Foundation
import FoundationModels
import CryptoKit
import NoodleCore

@available(macOS 27, *)
extension AppleTurnControl {
    /// OpenZot-style loop controls, applied to model input only. The native
    /// session remains the authoritative record of commands and their results.
    func prepare(_ original: LanguageModelExecutorGenerationRequest,
                 canDisableReasoning: Bool) throws -> LanguageModelExecutorGenerationRequest {
        try Task.checkCancellation()
        guard !finishing, generations < maximumGenerations else {
            throw HarnessSetupError("The model could not finish within this turn’s generation budget. Completed work is preserved.")
        }
        var request = original
        var entries = Array(request.transcript)
        if initialPromptID == nil {
            initialPromptID = entries.reversed().compactMap { entry -> String? in
                if case .prompt(let prompt) = entry { return prompt.id }; return nil
            }.first
        }
        // Recovery is part of the original task. Present the nudge as runtime
        // guidance, so context compaction cannot evict that task and its tool
        // receipts as though the nudge were a new user request.
        var recoveryNotice: String?
        if recovering, entries.contains(where: { $0.id == initialPromptID }) {
            entries.removeAll { entry in
                guard case .prompt(let prompt) = entry, prompt.id != initialPromptID,
                      AppleResponseRecovery.isRecoveryPrompt(prompt) else { return false }
                recoveryNotice = prompt.segments.compactMap { segment -> String? in
                    if case .text(let text) = segment { return text.content }; return nil
                }.joined()
                return true
            }
        }
        recordExchanges(entries)
        generations += 1
        if recovering && canDisableReasoning {
            // This convention is implemented by the pinned MLX adapter. Only
            // enable it when the loaded model has a toggleable chat template.
            request.contextOptions.reasoningLevel = .custom("no_think")
        } else if canDisableReasoning {
            // The adapter cannot budget thinking separately from the answer.
            // Bound the initial attempt so optional reasoning cannot consume
            // the whole inactivity allowance before recovery gets a chance.
            request.generationOptions.maximumResponseTokens = min(512, request.generationOptions.maximumResponseTokens ?? 512)
        }
        let repeats = Self.repeatedSuffix(recentExchanges)
        var notice: String?
        if generations == maximumGenerations || repeats >= 4 {
            finishing = true
            request.enabledToolDefinitions = []
            request.generationOptions.toolCallingMode = .disallowed
            notice = repeats >= 4
                ? "Repeated tool requests are returning the same results. No more tools are available this turn. Give a concise account of observed results and the unresolved blocker. Do not claim unfinished work is complete."
                : "This is the last generation available this turn. No more tools are available. Report verified results and clearly identify any unfinished work."
        } else if repeats >= 3 {
            notice = "The same tool requests and results are repeating. Use a materially different approach or explain the blocker. Do not repeat the same completed actions."
        } else if generations >= max(2, maximumGenerations * 9 / 10) {
            notice = "Very little of this turn’s generation budget remains. Finish essential checks now and give the final answer. State any unfinished work honestly."
        } else if generations >= max(2, maximumGenerations * 3 / 4) {
            notice = "Most of this turn’s generation budget has been used. Prioritize the remaining essential work and prepare the final answer."
        }
        let guidance = [recoveryNotice, notice].compactMap { $0 }.joined(separator: "\n")
        if !guidance.isEmpty {
            var annotated = entries
            if let index = annotated.firstIndex(where: { if case .instructions = $0 { return true }; return false }),
               case .instructions(var instructions) = annotated[index] {
                instructions.segments.append(.text(.init(content: "Runtime status: " + guidance)))
                annotated[index] = .instructions(instructions)
            }
            request.transcript = Transcript(entries: annotated)
        }
        return request
    }

    private func recordExchanges(_ entries: [Transcript.Entry]) {
        let calls = entries.flatMap { entry -> [Transcript.ToolCall] in
            if case .toolCalls(let calls) = entry { return Array(calls) }; return []
        }
        // Existing history belongs to previous turns and cannot consume this
        // turn's budget or make an ordinary repeated user request look stuck.
        if !initialized {
            initialized = true
            seenCalls.formUnion(calls.map(\.id))
            return
        }
        let byID = Dictionary(calls.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for entry in entries {
            guard case .toolOutput(let output) = entry, !seenCalls.contains(output.id),
                  let call = byID[output.id], call.toolName == output.toolName else { continue }
            seenCalls.insert(output.id)
            let arguments = call.arguments.jsonString
            let canonical = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)))
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? arguments
            let result = output.segments.map { segment -> String in
                if case .text(let text) = segment { return text.content }; return String(describing: segment)
            }.joined(separator: "\n")
            let fingerprint = call.toolName + "\u{0}" + canonical + "\u{0}" + result
            recentExchanges.append(SHA256.hash(data: Data(fingerprint.utf8)).description)
            recentExchanges = Array(recentExchanges.suffix(16))
        }
    }

    /// Detect one-action loops and short alternating cycles. Matching output
    /// alone is insufficient: different writes often return the same success.
    static func repeatedSuffix(_ values: [String]) -> Int {
        var most = 0
        for width in 1...4 where values.count >= width * 2 {
            let pattern = Array(values.suffix(width))
            var count = 1
            var end = values.count - width
            while end >= width && Array(values[(end - width)..<end]) == pattern {
                count += 1
                end -= width
            }
            most = max(most, count)
        }
        return most
    }
}
#endif
