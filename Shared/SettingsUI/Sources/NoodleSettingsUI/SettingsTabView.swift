import SwiftUI

/// The tab view every settings window uses. Like Safari, a newly chosen tab is
/// hidden while the window resizes to it, and fades in once the window has its size.
public struct SettingsTabView<Selection: Hashable, Content: View>: View {
    @Binding private var selection: Selection
    @State private var revealed: Selection
    private let content: Content

    private static var resizeDuration: Duration { .milliseconds(220) }

    public init(selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        _selection = selection
        _revealed = State(initialValue: selection.wrappedValue)
        self.content = content()
    }

    public var body: some View {
        // Compared in the same update that switches tabs, so the new tab never shows a frame early.
        let shown = revealed == selection
        TabView(selection: $selection.animation(.easeInOut(duration: 0.22))) { content }
            // Scoped to the opacity: hiding is instant, revealing fades.
            .animation(shown ? .easeOut(duration: 0.15) : nil) { $0.opacity(shown ? 1 : 0) }
            .modifier(TopResizeAnchor())
            .settingsScrollIndicators(selection: selection)
            .task(id: selection) {
                guard revealed != selection else { return }
                do { try await Task.sleep(for: Self.resizeDuration) }
                catch { return }
                revealed = selection
            }
    }
}

private struct TopResizeAnchor: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.windowResizeAnchor(.top) } else { content }
    }
}
