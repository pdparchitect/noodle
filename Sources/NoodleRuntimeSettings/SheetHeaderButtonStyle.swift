import SwiftUI

/// The text buttons in a sheet's top bar, such as Cancel and Save: in the accent colour, grey while disabled, without a bezel.
public struct SheetHeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == SheetHeaderButtonStyle {
    static var sheetHeader: SheetHeaderButtonStyle { SheetHeaderButtonStyle() }
}
