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

@available(macOS 27, *)
extension LanguageModelSession.DynamicProfile {
  /// Returns a modified profile that removes completed tool-call and
  /// tool-output entries from the transcript before each generation.
  ///
  /// Tool calls that have already been fulfilled add bulk to the
  /// transcript and are not always useful context for future responses.
  /// This modifier strips them from earlier turns, keeping every exchange
  /// for the current prompt and all non-tool entries.
  ///
  /// This transforms generation input without changing saved history.
  /// Summarization can still read the original completed actions:
  ///
  /// ```swift
  /// Profile {
  ///     Instructions("A helpful assistant.")
  /// }
  /// .summarizeHistory(entryThreshold: 50, model: model)
  /// .droppingCompletedToolCalls()
  /// ```
  ///
  /// - Returns: A profile that prunes completed tool-call entries from its
  ///   transcript before each generation.
  func droppingCompletedToolCalls() -> some DynamicProfile {
    modifier(DropCompletedToolCallsModifier())
  }
}

@available(macOS 27, *)
private struct DropCompletedToolCallsModifier: LanguageModelSession.DynamicProfileModifier {
  func body(content: Content) -> some DynamicProfile {
    content.historyTransform { history in
      // Noodle: retain every exchange for the current prompt. Keeping only
      // the latest call would lose earlier results in a multi-step task.
      let lastOutputIndex = history.lastIndex(where: { entry in
        if case .prompt = entry { return true }
        return false
      }) ?? history.startIndex

      let prefix = history.prefix(upTo: lastOutputIndex).filter { entry in
        if case .toolCalls = entry { return false }
        if case .toolOutput = entry { return false }
        return true
      }

      let suffix = history.suffix(from: lastOutputIndex)

      return prefix + suffix
    }
  }
}
#endif
