import Foundation
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// What Image Playground starts from when it makes a bot's picture: always an
/// avatar, steered by the bot's name and what it says about itself.
public struct AvatarIdea: Equatable, Sendable {
    public let phrases: [String]
    public let summary: String?

    /// The description wins over the backstory; Image Playground pulls its own
    /// concepts out of whichever is used.
    public init(name: String, description: String, backstory: String = "") {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        phrases = ["avatar portrait"] + (name.isEmpty ? [] : [name])
        summary = [description, backstory].lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    #if canImport(ImagePlayground)
    @available(macOS 15.1, iOS 18.1, *)
    public var concepts: [ImagePlaygroundConcept] {
        phrases.map { .text($0) } + (summary.map { [.extracted(from: $0, title: nil)] } ?? [])
    }
    #endif
}
