//===----------------------------------------------------------------------===//
//
// This source file is part of the Foundation Models open source project.
//
// Copyright © 2024-2027 Apple Inc. and the Foundation Models project authors.
//
// Licensed under the Apache License v2.0
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
// Noodle adaptation: SDK/OS availability guards and internal visibility.
// Provenance and local changes: Support/ThirdParty/FoundationModelsUtilities/README.md
#if canImport(FoundationModels, _version: 2)
import FoundationModels
import Foundation

@available(macOS 27, *)
extension LanguageModelSession.DynamicProfile {
  /// Returns a modified profile that summarizes the transcript when it
  /// exceeds an entry threshold, replacing older entries with a condensed
  /// summary.
  ///
  /// When the transcript's entry count grows past `entryThreshold`, a
  /// secondary language model session compresses the conversation history
  /// into a short summary that the modifier splices back into the transcript.
  /// The model still needs a token budget: a few large entries can overflow
  /// its context before this entry threshold is reached.
  ///
  /// Summarization updates stored history on a new prompt. It can be combined
  /// with completed-tool trimming, which transforms only generation input:
  ///
  /// ```swift
  /// Profile {
  ///     Instructions("A helpful assistant.")
  /// }
  /// .summarizeHistory(entryThreshold: 50, model: model)
  /// .droppingCompletedToolCalls()
  /// ```
  ///
  /// - Parameters:
  ///   - entryThreshold: The transcript entry count above which the
  ///     transcript will be summarized.
  ///   - model: The language model used to generate the summary.
  ///   - instructions: Optional custom instructions for the summarization
  ///     model. When `nil`, a default summarization prompt is used.
  ///   - summaryPostamble: Text appended after the summary to guide the
  ///     downstream model's response. The default forbids common
  ///     meta-reference phrases ("Based on the context", "Based on the
  ///     summary", etc.) that would otherwise leak the existence of the
  ///     summary into responses. Pass an empty string to omit the
  ///     postamble entirely.
  /// - Returns: A profile that automatically summarizes its transcript when
  ///   it exceeds the specified entry threshold.
  func summarizeHistory<Model: LanguageModel>(
    entryThreshold: Int,
    model: Model,
    instructions: Instructions? = nil,
    summaryPostamble: String? = nil
  ) -> some DynamicProfile {
    modifier(
      SummarizeHistoryModifier(
        entryThreshold: entryThreshold,
        model: model,
        instructions: instructions,
        summaryPostamble: summaryPostamble
      )
    )
  }
}

@available(macOS 27, *)
private struct SummarizeHistoryModifier<Model: LanguageModel>: LanguageModelSession
    .DynamicProfileModifier
{
  /// Default postamble appended after the summary. Discourages the
  /// downstream model from leaking the existence of the summary via
  /// phrases like "Based on the context provided".
  private static var defaultSummaryPostamble: String {
    """
    Do not begin with phrases like "Based on the \
    context", "Based on the facts", "Based on the summary", or any \
    reference to a summary or the facts provided. Treat the summary and facts \
    above as things you naturally remember.
    """
  }

  let entryThreshold: Int

  let model: Model

  let instructions: Instructions?

  let summaryPostamble: String?

  @SessionProperty(\.history)
  var history

  func body(content: Content) -> some DynamicProfile {
    content.onPrompt {

      guard history.count > entryThreshold else {
        return
      }

      guard case .prompt(let prompt) = history.last else {
        return
      }

      let session = LanguageModelSession(
        model: model,
        instructions: {
          instructions
            ?? Instructions {
              """
              Compress this conversation between an assistant and a \
              user into a concise summary that preserves:
              1. Established facts — names, numbers, dates, decisions, \
              preferences.
              2. The current topic and what stage the conversation is at.
              3. The thread most recently raised by the user — often \
              the immediate context for what comes next.
              4. Any open questions or unresolved items.

              Use compact third-person statements (for example: \
              "User's dog is named Pepper, a border collie." or \
              "User is choosing between two apartments and has just \
              decided office space is the deciding factor."). Do not \
              narrate the conversation with phrases like "the user \
              said" or "they discussed". Compress aggressively but do \
              not drop the active conversational thread.
              """
            }
        }
      )

      // Summarize completed history. The latest prompt remains the request to
      // execute, not material for a meta-summary of what the user is asking.
      let textRepresentation = history.dropLast().chatLog()

      // Noodle: summarization is an optimization. A large transcript can
      // exceed even the summarizer's budget; retain recent whole turns then
      // let the normal generation budget fit the next request. Never replay
      // tools or swallow cancellation because a summary failed.
      let summary: String
      do {
        summary = try await session.respond(
          to: Prompt {
            "Summarize this conversation:\n\n\(textRepresentation)"
          },
          options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 256)
        ).content
      } catch {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        guard AppleContextOverflow.matches(error) else { throw error }
        // Keep saved sessions bounded even when a large old turn prevents
        // summaries. Reuse the executor's whole-turn trimming, so calls and
        // results stay together and the current prompt always survives.
        var recent = Array(history)
        while recent.count > entryThreshold && AppleContextBudget.removeOldestTurn(&recent) {}
        history = .init(recent)
        return
      }
      try Task.checkCancellation()

      let postamble = summaryPostamble ?? Self.defaultSummaryPostamble
      var summaryContent = """
        Summary of the conversation so far:
        \(summary)
        """
      if !postamble.isEmpty {
        summaryContent += "\n\n\(postamble)"
      }
      summaryContent += "\n\n"
      let summarySegment = Transcript.TextSegment(content: summaryContent)

      history = [
        .prompt(
          Transcript.Prompt(
            id: UUID().uuidString,
            segments: [.text(summarySegment)] + prompt.segments,
            options: prompt.options,
            responseFormat: prompt.responseFormat
          )
        )
      ]
    }
  }
}
#endif
