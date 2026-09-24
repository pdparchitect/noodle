import NoodleWallpaper
import SwiftUI
import NoodleSettingsUI

typealias BrowserIconAppearance = IconAppearance

struct BrowserIcon: View {
    let appearance: BrowserIconAppearance
    let symbol: String
    let size: CGFloat
    var body: some View { IconBadge(appearance: appearance.clampingColour(), symbol: symbol, size: size) }
}

struct BrowserIconButton: View {
    @Binding var appearance: BrowserIconAppearance
    let symbol: String
    @State private var editing = false
    var body: some View {
        Button { editing = true } label: {
            ZStack(alignment: .bottomTrailing) {
                BrowserIcon(appearance: appearance, symbol: symbol, size: 64)
                Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor).font(.system(size: 21))
                    .background(.background, in: Circle())
            }
        }.buttonStyle(.plain).help("Change Browser Icon").accessibilityLabel("Change Browser Icon")
            .sheet(isPresented: $editing) { BrowserIconSheet(appearance: $appearance, symbol: symbol) }
    }
}

struct BrowserIconSheet: View {
    @Binding var appearance: BrowserIconAppearance
    let symbol: String
    private let symbols = ["desktopcomputer", "terminal", "shippingbox", "server.rack", "laptopcomputer", "globe",
        "sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "paintbrush.fill", "gearshape.2.fill"]
    var body: some View {
        IconEditorSheet(title: "Browser Icon",
            icon: Binding(get: { appearance.clampingColour() }, set: { appearance = $0 }),
            symbol: symbol, symbols: symbols, encoding: .png(maxBytes: 2 * 1024 * 1024))
            .noodleSheetSizing()
    }
}
