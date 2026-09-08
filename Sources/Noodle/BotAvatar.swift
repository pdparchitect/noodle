import AppKit
import SwiftUI
import NoodleCore

enum BotAvatarPalette {
    static let gradients: [[Color]] = [
        [.blue, .cyan],
        [.purple, .pink],
        [.orange, .yellow],
        [.mint, .teal],
        [.indigo, .blue],
        [.pink, .orange]
    ]
}

/// Shared by conversations, profiles and the native name menu.
struct BotAvatar: View {
    let agent: AgentRecord
    let size: CGFloat
    var showsShadow = true

    private var palette: [Color] {
        let index = agent.avatarColorIndex ?? agent.accentSeed
        return BotAvatarPalette.gradients[abs(index) % BotAvatarPalette.gradients.count]
    }

    var body: some View {
        ZStack {
            if let data = agent.avatarImageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))

                Image(systemName: agent.avatarSymbolName ?? "sparkles")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: .black.opacity(showsShadow ? 0.2 : 0), radius: 3, y: 1)
        .accessibilityHidden(true)
    }

    @MainActor static func menuImage(for agent: AgentRecord) -> NSImage? {
        let size: CGFloat = 16
        let renderer = ImageRenderer(content: BotAvatar(agent: agent, size: size, showsShadow: false))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: size, height: size))
        result.isTemplate = false
        return result
    }
}
