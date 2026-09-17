import SwiftUI

public enum CompanionContentGeometry {
    public static let cornerRadius: CGFloat = 20
}

public extension View {
    /// The shared Computer/Browser content edge, aligned with native sidebar glass.
    func companionContentPanel(sidebarCollapsed: Bool) -> some View {
        clipShape(RoundedRectangle(cornerRadius: CompanionContentGeometry.cornerRadius, style: .continuous).inset(by: 1))
            .padding(.leading, sidebarCollapsed ? 8 : 12)
            .padding(.trailing, 8)
            .padding(.top, 4)
            .padding(.bottom, 7)
    }
}
