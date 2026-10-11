import Foundation

/// Picks which decision backend answers a call: the user's chosen model, a
/// vision-capable fallback when the state carries images, or the on-device
/// model. When every backend fails the error propagates and callers keep their
/// unverified current behavior — decision fields are an enhancement, never a
/// dependency.
public struct DecisionModelRouter: DecisionModelServing {
    public let preferred: any DecisionModelServing
    /// Vision-capable backends, cheapest first, consulted when the state has
    /// images and `preferred` cannot read them.
    public let visionFallbacks: [any DecisionModelServing]
    /// Last resort for text states; used when the preferred backend errors.
    public let onDevice: AppleDecisionModel

    public init(preferred: any DecisionModelServing,
                visionFallbacks: [any DecisionModelServing] = [],
                onDevice: AppleDecisionModel = AppleDecisionModel()) {
        self.preferred = preferred
        self.visionFallbacks = visionFallbacks
        self.onDevice = onDevice
    }

    /// Usable when any backend is: the preferred cloud model or the on-device fallback.
    public var isAvailable: Bool { preferred.isAvailable || onDevice.isAvailable }
    /// Whether any image-capable backend exists for image states.
    public var supportsImages: Bool { preferred.supportsImages || visionFallbacks.contains { $0.supportsImages } }

    public func decide(state: [String: any Sendable], questions: [String: DecisionQuestion]) async throws -> [String: DecisionAnswer] {
        let hasImages = state.values.contains { $0 is DecisionImage }

        // Image states need a vision backend; the preferred model is skipped,
        // not asked to guess from a label.
        if hasImages {
            for serving in [preferred] + visionFallbacks where serving.supportsImages && serving.isAvailable {
                if let answers = try? await serving.decide(state: state, questions: questions) { return answers }
            }
            throw HarnessSetupError("No available decision model can read this image state.")
        }

        if preferred.isAvailable, let answers = try? await preferred.decide(state: state, questions: questions) {
            return answers
        }
        if onDevice.isAvailable {
            return try await onDevice.decide(state: state, questions: questions)
        }
        throw HarnessSetupError("No decision backend answered; callers fall back to unverified behavior.")
    }
}
