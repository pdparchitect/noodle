import AppKit
import HubLink
import TerminalCore

/// Bots' and groups' pictures as the Mac and phone draw them, made into PNGs the terminal shows: the bot's own
/// picture, or its symbol on its colour, in a circle; a group's first bots together. A terminal that can show
/// pictures shows them as they are; any other shows them in coloured blocks.
@MainActor enum Pictures {
    /// The same gradients as the Mac's bot avatars, indexed the same way.
    private static let gradients: [[NSColor]] = [
        [.systemBlue, .systemCyan], [.systemPurple, .systemPink], [.systemOrange, .systemYellow], [.systemMint, .systemTeal],
        [.systemIndigo, .systemBlue], [.systemPink, .systemOrange],
    ]
    static let colourNames = ["Blue", "Purple", "Orange", "Mint", "Indigo", "Pink"]
    private static var made: [String: [UInt8]] = [:]
    private static let pixels = 48

    /// Bots may store any integer; it wraps onto the palette.
    static func colourIndex(_ colour: Int) -> Int { Int(colour.magnitude % UInt(gradients.count)) }

    /// `scale` draws the picture smaller within its square, with clear space around it, so it shrinks without the
    /// terminal stretching it out of shape.
    static func png(for thread: HubThread, in chats: HubChats, scale: Double = 1) -> [UInt8] {
        switch thread {
        case .bot(let bot):
            return png(for: [bot.draft], dimmed: isIdle(bot.phase), scale: scale)
        case .group(let group):
            let members = chats.members(of: group).filter { $0.archivedAt == nil }
            return png(for: members.map(\.draft), dimmed: members.allSatisfy { isIdle($0.phase) }, scale: scale)
        }
    }

    /// A stopped or starting bot is greyed out, as on the Mac.
    private static func isIdle(_ phase: LinkBotPhase?) -> Bool { phase == .offline || phase == .starting }

    static func png(for faces: [LinkBotDraft], dimmed: Bool = false, scale: Double = 1) -> [UInt8] {
        // The picture itself, not only its digest: a list names the picture before it arrives, and what is drawn
        // without it must not be kept for once it is here.
        let key = faces.map { "\($0.avatarImageData.map { "\($0.count)-\($0.hashValue)" } ?? "none")|\($0.avatarSymbolName ?? "")|\($0.avatarColorIndex)" }
            .joined(separator: ",") + (dimmed ? "-dim" : "") + "@\(scale)"
        if let kept = made[key] { return kept }
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { full in
            let side = full.width * scale
            let rect = NSRect(x: full.midX - side / 2, y: full.midY - side / 2, width: side, height: side)
            let shown = Array(faces.prefix(3))
            switch shown.count {
            case 0: draw(nil, in: rect)
            case 1: draw(shown[0], in: rect)
            default:
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                let size = rect.width * (shown.count == 2 ? 0.6 : 0.62)
                for (index, face) in shown.enumerated() {
                    let offset = groupOffset(index, of: shown.count, size: rect.width)
                    draw(face, in: NSRect(x: rect.midX - size / 2 + offset.x, y: rect.midY - size / 2 - offset.y, width: size, height: size))
                }
            }
            return true
        }
        let png = encode(image, dimmed: dimmed)
        made[key] = png
        return png
    }

    private static func draw(_ face: LinkBotDraft?, in rect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        NSBezierPath(ovalIn: rect).addClip()
        if let data = face?.avatarImageData, let picture = NSImage(data: data) {
            picture.draw(in: fill(picture.size, into: rect))
            return
        }
        let colours = gradients[colourIndex(face?.avatarColorIndex ?? 0)]
        NSGradient(starting: colours[0], ending: colours[1])?.draw(in: rect, angle: -45)
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.45, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: face?.avatarSymbolName ?? "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// As the Mac lays out a group's bots: two across the middle, three in a triangle.
    private static func groupOffset(_ index: Int, of count: Int, size: CGFloat) -> CGPoint {
        switch (count, index) {
        case (2, 0): CGPoint(x: -size * 0.14, y: -size * 0.14)
        case (2, _): CGPoint(x: size * 0.14, y: size * 0.14)
        case (_, 0): CGPoint(x: -size * 0.18, y: -size * 0.14)
        case (_, 1): CGPoint(x: size * 0.18, y: -size * 0.14)
        default: CGPoint(x: 0, y: size * 0.19)
        }
    }

    /// The picture's rectangle filling `rect`, cropped rather than squashed.
    private static func fill(_ size: NSSize, into rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private static func encode(_ image: NSImage, dimmed: Bool) -> [UInt8] {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: dimmed ? 0.45 : 1)
        NSGraphicsContext.restoreGraphicsState()
        return [UInt8](bitmap.representation(using: .png, properties: [:]) ?? Data())
    }
}
