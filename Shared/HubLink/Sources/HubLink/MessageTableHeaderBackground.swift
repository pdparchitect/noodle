#if canImport(SwiftUI)
import SwiftUI

private struct MessageTableHeaderBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

public extension View {
    func messageTableHeaderCell() -> some View {
        anchorPreference(key: MessageTableHeaderBounds.self, value: .bounds) { [$0] }
    }

    func messageTableHeaderBackground() -> some View {
        // Resolve the current cells on every layout, including when text shrinks.
        // One band spans the row even when individual headings have different heights.
        backgroundPreferenceValue(MessageTableHeaderBounds.self) { anchors in
            GeometryReader { geometry in
                Color.primary.opacity(0.06)
                    .frame(height: anchors.map { geometry[$0].maxY }.max() ?? 0)
            }
        }
    }
}
#endif
