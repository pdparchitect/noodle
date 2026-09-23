import SwiftUI

public struct SettingsStatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    public var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize()
    }

    public init(title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }
}
