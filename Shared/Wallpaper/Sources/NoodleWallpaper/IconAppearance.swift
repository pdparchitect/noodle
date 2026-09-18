import AppKit
import ImageIO
import SwiftUI

/// The circular icon shared by bots, browsers and computers: a custom image, or
/// a symbol on one of six gradients.
public struct IconAppearance: Equatable, Sendable {
    public var iconSymbol: String?
    public var iconColour: Int
    public var iconImage: Data?

    public init(symbol: String? = nil, colour: Int = 0, image: Data? = nil) {
        iconSymbol = symbol; iconColour = colour; iconImage = image
    }

    /// For apps that store a palette index: a stray one is pinned to the nearest end.
    public func clampingColour() -> IconAppearance {
        var icon = self
        icon.iconColour = IconPalette.clamped(iconColour)
        return icon
    }
}

public enum IconPalette {
    public static let gradients: [[Color]] = [
        [.blue, .cyan], [.purple, .pink], [.orange, .yellow],
        [.mint, .teal], [.indigo, .blue], [.pink, .orange]
    ]

    /// Bots store an arbitrary seed rather than a palette index, so any integer
    /// wraps onto the palette. Indexes already in range are unchanged.
    public static func index(for colour: Int) -> Int {
        Int(colour.magnitude % UInt(gradients.count))
    }

    /// Browsers and computers store a palette index, and pin a stray one to the nearest end.
    public static func clamped(_ colour: Int) -> Int {
        max(0, min(gradients.count - 1, colour))
    }
}

public struct IconBadge: View {
    let appearance: IconAppearance
    let symbol: String
    let size: CGFloat
    var showsShadow = true

    /// `symbol` is drawn while the appearance has not chosen one of its own.
    public init(appearance: IconAppearance, symbol: String, size: CGFloat, showsShadow: Bool = true) {
        self.appearance = appearance; self.symbol = symbol; self.size = size; self.showsShadow = showsShadow
    }

    public var body: some View {
        ZStack {
            if let data = appearance.iconImage, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(LinearGradient(colors: IconPalette.gradients[IconPalette.index(for: appearance.iconColour)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: appearance.iconSymbol ?? symbol)
                    .font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            }
        }.frame(width: size, height: size).clipShape(Circle())
            .shadow(color: .black.opacity(showsShadow ? 0.2 : 0), radius: 3, y: 1).accessibilityHidden(true)
    }
}

/// How an app stores a chosen icon image. Existing icons in either format keep decoding.
public enum IconImageEncoding: Sendable {
    /// Lossless, refused above `maxBytes` so it stays small enough for the app's settings file.
    case png(maxBytes: Int)
    case jpeg(quality: Double)
}

public enum IconImageError: LocalizedError, Equatable {
    case invalidImage, sourceTooLarge, encodedTooLarge, photosUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "That image could not be used."
        case .sourceTooLarge: "Choose an image smaller than 50 MB."
        case .encodedTooLarge: "The image is too large. Choose a smaller image."
        case .photosUnavailable: "Photos could not provide this image. Try Choose File instead."
        }
    }
}

public enum IconImage {
    static let maxSourceBytes = 50 * 1024 * 1024

    /// Scales the image to fit 512 pixels, applying its orientation, and encodes it for storage.
    public static func prepare(_ data: Data, encoding: IconImageEncoding) throws -> Data {
        guard data.count <= maxSourceBytes else { throw IconImageError.sourceTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw IconImageError.invalidImage }
        let bitmap = NSBitmapImageRep(cgImage: image)
        switch encoding {
        case .png(let maxBytes):
            guard let encoded = bitmap.representation(using: .png, properties: [:]) else { throw IconImageError.invalidImage }
            guard encoded.count <= maxBytes else { throw IconImageError.encodedTooLarge }
            return encoded
        case .jpeg(let quality):
            guard let encoded = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
                throw IconImageError.invalidImage
            }
            return encoded
        }
    }

    public static func load(_ url: URL, encoding: IconImageEncoding) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maxSourceBytes else {
            throw IconImageError.sourceTooLarge
        }
        return try prepare(Data(contentsOf: url), encoding: encoding)
    }
}
