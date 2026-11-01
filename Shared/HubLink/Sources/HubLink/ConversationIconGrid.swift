import SwiftUI

/// How the conversation list shows bots and groups: as rows, or as a grid of their pictures.
public enum ConversationListStyle: String, CaseIterable, Identifiable, Sendable {
    case list, icons

    public static let key = "sidebarStyle"
    public static let standard = Self.list
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .list: "As List"
        case .icons: "As Icons"
        }
    }
}

/// The icon view's grid, on the Mac and on iPhone and iPad: as many columns of at least 96 points as fit, each row as tall as its tallest picture.
/// Every picture is laid out, unlike a lazy grid, which in a list row only ever drew those first on screen.
public struct ConversationIconGrid: Layout {
    public init() {}

    private let minimumWidth: CGFloat = 96, columnSpacing: CGFloat = 6, rowSpacing: CGFloat = 8

    private struct Grid {
        let columns: Int, itemWidth: CGFloat, rowHeights: [CGFloat]
    }

    private func grid(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Grid {
        // Asked for its smallest or largest size, it is one column or one row.
        let width = width(proposal, subviews)
        let columns = max(1, Int((width + columnSpacing) / (minimumWidth + columnSpacing)))
        let itemWidth = max(0, (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns))
        let rowHeights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
        }
        return Grid(columns: columns, itemWidth: itemWidth, rowHeights: rowHeights)
    }

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        guard let width = proposal.width else { return minimumWidth }
        guard width.isFinite else { return CGFloat(subviews.count) * (minimumWidth + columnSpacing) - columnSpacing }
        return width
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = grid(proposal, subviews)
        let height = grid.rowHeights.reduce(0, +) + rowSpacing * CGFloat(max(0, grid.rowHeights.count - 1))
        return CGSize(width: width(proposal, subviews), height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(ProposedViewSize(width: bounds.width, height: nil), subviews)
        var y = bounds.minY
        for (row, height) in grid.rowHeights.enumerated() {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (grid.itemWidth + columnSpacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: grid.itemWidth, height: height))
            }
            y += height + rowSpacing
        }
    }
}
