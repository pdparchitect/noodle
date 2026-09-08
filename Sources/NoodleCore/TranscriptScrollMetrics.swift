import Foundation

/// Scroll geometry only; observing it must never trigger another scroll.
public struct TranscriptScrollMetrics: Equatable, Sendable {
    public let offset: CGFloat
    public let isAtBottom: Bool

    public init(contentOffset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
                topInset: CGFloat, bottomInset: CGFloat) {
        let adjustedOffset = contentOffset + topInset
        let maximumOffset = max(0, contentHeight + topInset + bottomInset - viewportHeight)
        offset = max(0, adjustedOffset)
        // A short conversation is already fully visible, even when its raw
        // offset is negative because of the titlebar/safe-area inset.
        isAtBottom = maximumOffset <= 2 || adjustedOffset >= maximumOffset - 2
    }
}
