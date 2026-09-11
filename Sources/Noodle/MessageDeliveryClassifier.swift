import Foundation
import NoodleCore
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
protocol MessageDeliveryClassifying {
    var isAvailable: Bool { get }
    func shouldSendImmediately(_ context: MessageDeliveryContext) async throws -> Bool
}

@MainActor
struct MessageDeliveryClassifier: MessageDeliveryClassifying {
    nonisolated init() {}
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    func shouldSendImmediately(_ context: MessageDeliveryContext) async throws -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            // Use a fresh session so one conversation cannot influence another.
            let session = LanguageModelSession()
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
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 16))
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
@available(macOS 26.0, *)
@Generable
private enum MessageDeliveryIntent {
    case stop, correction, emergency, additionalTask, acknowledgement, question, unclear
}
#endif
