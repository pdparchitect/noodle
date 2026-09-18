import AppKit
import SwiftUI
import NoodleCore

enum BotAvatarPalette {
    static let gradients = IconPalette.gradients
}

/// Shared by conversations, profiles and the native name menu.
struct BotAvatar: View {
    static let defaultSymbol = "sparkles"
    let agent: AgentRecord
    let size: CGFloat
    var showsShadow = true

    var body: some View {
        IconBadge(
            appearance: IconAppearance(
                symbol: agent.avatarSymbolName,
                colour: agent.avatarColorIndex ?? agent.accentSeed,
                image: agent.avatarImageData
            ),
            symbol: Self.defaultSymbol,
            size: size,
            showsShadow: showsShadow
        )
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
