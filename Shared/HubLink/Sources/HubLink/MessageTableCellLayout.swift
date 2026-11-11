#if canImport(SwiftUI)
import SwiftUI

/// Caps a cell's ideal width before measuring its height. A flexible frame alone
/// lets Grid measure the unwrapped ideal height, then wrap the text during placement.
public struct MessageTableCellLayout: Layout {
    public var maxWidth: CGFloat

    public init(maxWidth: CGFloat) {
        self.maxWidth = maxWidth
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let cell = subviews.first else { return .zero }
        let ideal = cell.sizeThatFits(.unspecified)
        let width = min(maxWidth, proposal.width ?? ideal.width, ideal.width)
        return cell.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
#endif
