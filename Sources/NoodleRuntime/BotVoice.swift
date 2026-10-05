import Foundation
import NoodleCore
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor public protocol VoicePresentationGuessing {
    func presentation(forName name: String) async -> VoicePresentation?
}

/// Asks the on-device model, which knows names from many languages. Without Apple
/// Intelligence the harness's own default voice is used.
public struct AppleVoicePresentationGuesser: VoicePresentationGuessing {
    public init() {}

    public func presentation(forName name: String) async -> VoicePresentation? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession()
        // The macOS 26 SDK used by CI predates the samplingMode label.
        #if canImport(FoundationModels, _version: 2)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
        #endif
        // Offered "either", the model hedges even on names like Alfred, so it has to choose.
        let response = try? await session.respond(
            to: "People named \(name): are they more often women or men? Answer with the more common one.",
            generating: NamePresentation.self, options: options)
        return switch response?.content {
        case .woman: .feminine
        case .man: .masculine
        case nil: nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
private enum NamePresentation {
    case woman, man
}
#endif


/// The voice a bot speaks with on calls, wherever it runs.
@MainActor
public enum BotVoice {
    /// What a bot with this name sounds like until a voice is chosen for it.
    public static func fitting(name: String, harnessIdentifier: String, guesser: any VoicePresentationGuessing) async -> String? {
        guard let provider = HarnessProvider(rawValue: harnessIdentifier), !provider.voices.isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return provider.defaultVoice(for: await guesser.presentation(forName: name))
    }

    /// The bot's chosen voice. One without gets one matching its name, kept so it always sounds
    /// the same. Nil leaves it to the harness.
    public static func forCall(_ agent: AgentRecord, repository: WorkspaceRepository,
                               guesser: any VoicePresentationGuessing) async -> String? {
        let voices = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.voices.map(\.id) ?? []
        if let saved = try? repository.loadAgentVoice(agent), voices.contains(saved) { return saved }
        guard let fitting = await fitting(name: agent.displayName, harnessIdentifier: agent.harnessIdentifier ?? "", guesser: guesser)
        else { return nil }
        try? repository.updateAgentVoice(agent, voice: fitting)
        return fitting
    }
}
