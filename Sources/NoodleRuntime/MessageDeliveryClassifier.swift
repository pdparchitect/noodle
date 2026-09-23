import Foundation
import NoodleCore
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
package protocol MessageDeliveryClassifying {
    var isAvailable: Bool { get }
    func shouldSendImmediately(_ context: MessageDeliveryContext) async throws -> Bool
}

@MainActor
package struct MessageDeliveryClassifier: MessageDeliveryClassifying {
    nonisolated init() {}
    package var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }

    package func shouldSendImmediately(_ context: MessageDeliveryContext) async throws -> Bool {
        #if canImport(FoundationModels)
        if isAvailable {
            // Use a fresh session so one conversation cannot influence another.
            let session = LanguageModelSession()
            // The macOS 26 SDK used by CI predates the samplingMode label.
            #if canImport(FoundationModels, _version: 2)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
            #else
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
            #endif
            let response = try await session.respond(to: """
                A coding assistant is currently working on a task. Classify the intent of the user's new message into one category:
                stop: stop or pause the current work
                correction: change or correct what the assistant is doing now
                emergency: something requires immediate attention before the current work finishes
                additionalTask: extra work, a task for afterwards, a future deadline, or content to create such as button labels
                acknowledgement: thanks or agreement
                question: a question that allows the work to continue
                unclear: none of the above or ambiguous
                \(context.prompt)
                Classify the new message.
                """, generating: MessageDeliveryIntent.self,
                options: options)
            switch response.content {
            case .stop, .correction, .emergency: return true
            case .additionalTask, .acknowledgement, .question, .unclear: return false
            }
        }
        #endif
        return false
    }
}

#if canImport(FoundationModels)
@Generable
private enum MessageDeliveryIntent {
    case stop, correction, emergency, additionalTask, acknowledgement, question, unclear
}
#endif
