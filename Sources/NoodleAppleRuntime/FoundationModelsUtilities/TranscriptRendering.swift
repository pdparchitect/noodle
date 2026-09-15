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
extension Transcript.Entry {
  /// Plain-text role-tagged rendering of this entry, suitable for embedding
  /// in an LLM prompt. Returns `nil` for entries without conversational
  /// text (for example, `.instructions`).
  var chatText: String? {
    switch self {
    case .prompt(let prompt):
      return "User: \(prompt.segments.textContent)"
    case .response(let response):
      return "Assistant: \(response.segments.textContent)"
    case .reasoning(let reasoning):
      return "Assistant (reasoning): \(reasoning.segments.textContent)"
    case .toolCalls(let calls):
      let rendered =
        calls
        .map { "\($0.toolName)(\($0.arguments))" }
        .joined(separator: ", ")
      return "Tool call: \(rendered)"
    case .toolOutput(let output):
      return "Tool output (\(output.toolName)): \(output.segments.textContent)"
    case .instructions:
      return nil
    @unknown default:
      return nil
    }
  }
}

@available(macOS 27, *)
extension Sequence where Element == Transcript.Entry {
  /// Renders the entries as role-tagged lines joined by `separator`,
  /// omitting non-conversational entries.
  func chatLog(separator: String = "\n") -> String {
    compactMap(\.chatText).joined(separator: separator)
  }
}

@available(macOS 27, *)
extension Sequence where Element == Transcript.Segment {
  /// Concatenates the textual content of any text segments, ignoring
  /// structured content and attachments.
  var textContent: String {
    compactMap { segment in
      if case .text(let textSegment) = segment {
        return textSegment.content
      }
      return nil
    }
    .joined(separator: " ")
  }
}
#endif
