import HubLink
import ImageIO
import SwiftUI
import UIKit

/// A bot as its avatar shows it: its picture, or its symbol on its colour.
struct BotFace: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var picture: Data?
    var symbol: String?
    var colour: Int

    init(_ draft: LinkBotDraft, id: UUID) {
        self.id = id
        name = draft.name
        picture = draft.avatarImageData
        symbol = draft.avatarSymbolName
        colour = draft.avatarColorIndex
    }

    init(_ bot: LinkBot) { self.init(bot.draft, id: bot.id) }
}

/// The bot's picture, or its symbol on its colour, as Noodle on the Mac shows it.
struct AgentAvatar: View {
    /// The same gradients as the Mac's bot avatars, indexed the same way.
    private static let gradients: [[Color]] = [
        [.blue, .cyan], [.purple, .pink], [.orange, .yellow], [.mint, .teal], [.indigo, .blue], [.pink, .orange],
    ]
    let face: BotFace
    let size: CGFloat
    /// Shown on the picture, as on the Mac. Nil shows none.
    var phase: LinkBotPhase?

    init(face: BotFace, size: CGFloat, phase: LinkBotPhase? = nil) {
        self.face = face
        self.size = size
        self.phase = phase
    }

    init(draft: LinkBotDraft, size: CGFloat, phase: LinkBotPhase? = nil) {
        self.init(face: BotFace(draft, id: UUID()), size: size, phase: phase)
    }

    static var colourCount: Int { gradients.count }


    /// Bots may store any integer; it wraps onto the palette.
    static func colourIndex(_ colour: Int) -> Int { Int(colour.magnitude % UInt(gradients.count)) }

    static func swatch(_ index: Int) -> some View {
        Circle().fill(LinearGradient(colors: gradients[index], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    var body: some View {
        Group {
            if let data = face.picture, let image = DecodedImages.picture(data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Self.swatch(Self.colourIndex(face.colour))
                    .overlay {
                        Image(systemName: face.symbol ?? "sparkles")
                            .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .statusLook(phase, size: size)
    }
}

extension View {
    /// As on the Mac: a ready bot is shown as it is, a working one circled, a stopped or starting one
    /// greyed out, and one waiting for Kick marked with a red dot. The marks scale with the picture's `size`.
    func statusLook(_ phase: LinkBotPhase?, size: CGFloat) -> some View {
        let isIdle = phase == .offline || phase == .starting
        let ringWidth = max(1, size * 0.045)
        return grayscale(isIdle ? 1 : 0)
            .opacity(isIdle ? 0.5 : 1)
            .overlay {
                if phase == .working { WorkingRing(lineWidth: ringWidth).padding(-(ringWidth / 2 + max(1, size * 0.04))) }
            }
            .overlay(alignment: .bottomTrailing) {
                if phase == .failed {
                    let dot = max(8, size * 0.24)
                    Circle().fill(.red)
                        .frame(width: dot, height: dot)
                        .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phase?.rawValue.capitalized ?? "")
            .accessibilityHidden(phase == nil)
    }
}

/// An arc that circles a working bot's picture.
private struct WorkingRing: View {
    let lineWidth: CGFloat
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// A group's picture: its first bots together, as Noodle on the Mac shows a group.
struct GroupAvatar: View {
    let faces: [BotFace]
    let size: CGFloat
    /// The members' status together, as `phase(of:)` works it out. Nil shows none.
    var phase: LinkBotPhase? = nil
    /// The members shown gray among the others, as suspended ones are.
    var grayFaces: Set<UUID> = []

    /// As on the Mac: a working member wins, then one waiting for Kick, then any that can answer; otherwise idle.
    static func phase(of members: [LinkBotPhase?]) -> LinkBotPhase? {
        let known = members.compactMap { $0 }
        if known.isEmpty { return nil }
        if known.contains(.working) { return .working }
        if known.contains(.failed) { return .failed }
        return known.contains(.ready) ? .ready : .offline
    }

    var body: some View {
        pictures.statusLook(phase, size: size)
    }

    @ViewBuilder private var pictures: some View {
        if faces.count == 1, let face = faces.first {
            // One bot in front of a disc, so it still reads as a group.
            ZStack {
                Circle().fill(.quaternary).frame(width: size * 0.88, height: size * 0.88)
                    .offset(x: size * 0.06, y: size * 0.06)
                AgentAvatar(face: face, size: size * 0.86)
                    .overlay { Circle().stroke(Color(.systemBackground), lineWidth: max(1, size * 0.04)) }
                    .offset(x: -size * 0.06, y: -size * 0.06)
            }
            .frame(width: size, height: size)
        } else {
            let shown = Array(faces.prefix(3))
            ZStack {
                Circle().fill(.quaternary)
                ForEach(Array(shown.enumerated()), id: \.offset) { index, face in
                    AgentAvatar(face: face, size: size * (shown.count == 2 ? 0.6 : 0.62))
                        // Gray but opaque: the faces overlap, and a group nobody can answer in is dimmed as a whole.
                        .grayscale(grayFaces.contains(face.id) ? 1 : 0)
                        // Thinner on a small picture, where a fixed border would cover much of each face.
                        .overlay { Circle().stroke(Color(.systemBackground), lineWidth: max(1, size * 0.04)) }
                        .offset(Self.offset(index, of: shown.count, size: size))
                }
            }
            .frame(width: size, height: size)
        }
    }

    private static func offset(_ index: Int, of count: Int, size: CGFloat) -> CGSize {
        // Two sit diagonally across the middle, as large as the circle holds them, as on the Mac.
        switch (count, index) {
        case (2, 0): CGSize(width: -size * 0.14, height: -size * 0.14)
        case (2, _): CGSize(width: size * 0.14, height: size * 0.14)
        case (_, 0): CGSize(width: -size * 0.18, height: -size * 0.14)
        case (_, 1): CGSize(width: size * 0.18, height: -size * 0.14)
        default: CGSize(width: 0, height: size * 0.19)
        }
    }
}

/// Pictures decoded once and kept while memory allows, so a bubble, card or avatar drawn again, as
/// when scrolled back into view, shows at once rather than decoding again on the main thread.
enum DecodedImages {
    private nonisolated(unsafe) static let pictures: NSCache<NSData, UIImage> = cache()
    private nonisolated(unsafe) static let files: NSCache<NSString, UIImage> = cache()

    private static func cache<Key>() -> NSCache<Key, UIImage> {
        let cache = NSCache<Key, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }

    /// What it takes in memory, so the caches stay within their limit.
    private static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }

    /// The picture in these bytes, decoded ready to draw.
    static func picture(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let image = pictures.object(forKey: key) { return image }
        guard let decoded = UIImage(data: data) else { return nil }
        let image = decoded.preparingForDisplay() ?? decoded
        pictures.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    /// A file's picture as decoded at this size before, if it still is.
    static func shown(_ file: URL, at pixels: Int) -> UIImage? {
        files.object(forKey: key(file, pixels))
    }

    static func keep(_ image: UIImage, of file: URL, at pixels: Int) {
        files.setObject(image, forKey: key(file, pixels), cost: cost(of: image))
    }

    /// Decodes only as many pixels as are shown, once.
    static func downsampled(_ file: URL, to pixels: Int) -> UIImage? {
        if let image = shown(file, at: pixels) { return image }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: decoded)
        keep(image, of: file, at: pixels)
        return image
    }

    private static func key(_ file: URL, _ pixels: Int) -> NSString { "\(pixels) \(file.path)" as NSString }
}
