import SwiftUI

struct SettingsStatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize()
    }
}
