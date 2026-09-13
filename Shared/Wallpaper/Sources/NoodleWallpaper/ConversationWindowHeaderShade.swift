import SwiftUI

/// Fade scrolling content beneath the toolbar to reveal the shaded wallpaper.
/// Apply this mask to the detail scroll view, leaving the sidebar untouched.
public struct ConversationContentTopFade: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.12), location: 0.45),
                .init(color: .white, location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: 88)
            Color.white
        }
        .ignoresSafeArea(edges: .top)
    }
}

/// An edge-to-edge fade on the wallpaper, underneath both split-view columns.
/// It must not wash over sidebar content or stop at the conversation boundary.
public struct ConversationWindowHeaderShade: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.24), location: 0),
                    .init(color: .black.opacity(0.10), location: 0.5),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.88), location: 0.55),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 88)
            .shadow(color: .black.opacity(0.24), radius: 14, y: 5)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
