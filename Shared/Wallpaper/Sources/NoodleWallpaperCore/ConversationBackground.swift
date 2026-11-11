import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The built-in gradients in picker order, a row of ten each for pastel, bright, deep and neutral.
/// The raw value is what gets stored and sent to the Hub; a name a build no longer knows loads as the default.
public enum ConversationBackgroundPreset: String, Codable, CaseIterable, Sendable {
    case blush, peach, butter, pistachio, mint, seafoam, powder, lavender, lilac, candy
    case cherry, ember, sunset, amber, citrus, lime, lagoon, sky, violet, orchid
    case forest, jade, aurora, ocean, cobalt, midnight, dusk, nebula, twilight, plum
    case pearl, fog, sand, stone, sage, taupe, mocha, slate, storm, graphite

    public struct Stop: Hashable, Sendable {
        public let red, green, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
        #if canImport(SwiftUI)
        public var color: Color { Color(red: red, green: green, blue: blue) }
        #endif
    }

    public var name: String { rawValue.capitalized }

    /// Start, glow and end of the diagonal gradient.
    public var stops: [Stop] {
        switch self {
        case .blush: [Stop(1.00, 0.78, 0.82), Stop(1.00, 0.90, 0.88), Stop(0.96, 0.76, 0.90)]
        case .peach: [Stop(1.00, 0.82, 0.70), Stop(1.00, 0.92, 0.80), Stop(0.98, 0.78, 0.78)]
        case .butter: [Stop(1.00, 0.93, 0.70), Stop(1.00, 0.98, 0.85), Stop(0.96, 0.86, 0.72)]
        case .pistachio: [Stop(0.80, 0.92, 0.72), Stop(0.92, 0.98, 0.84), Stop(0.74, 0.88, 0.80)]
        case .mint: [Stop(0.72, 0.94, 0.85), Stop(0.88, 0.99, 0.93), Stop(0.70, 0.88, 0.90)]
        case .seafoam: [Stop(0.70, 0.92, 0.94), Stop(0.86, 0.98, 0.98), Stop(0.72, 0.84, 0.96)]
        case .powder: [Stop(0.76, 0.86, 1.00), Stop(0.90, 0.95, 1.00), Stop(0.80, 0.80, 0.98)]
        case .lavender: [Stop(0.84, 0.80, 1.00), Stop(0.94, 0.90, 1.00), Stop(0.90, 0.78, 0.96)]
        case .lilac: [Stop(0.94, 0.78, 0.96), Stop(0.98, 0.90, 0.98), Stop(0.84, 0.76, 0.98)]
        case .candy: [Stop(1.00, 0.80, 0.90), Stop(0.88, 0.88, 1.00), Stop(0.78, 0.92, 1.00)]
        case .cherry: [Stop(0.62, 0.08, 0.22), Stop(0.95, 0.30, 0.40), Stop(0.45, 0.06, 0.25)]
        case .ember: [Stop(0.80, 0.22, 0.10), Stop(1.00, 0.50, 0.25), Stop(0.60, 0.12, 0.18)]
        case .sunset: [Stop(0.96, 0.52, 0.15), Stop(0.77, 0.43, 0.67), Stop(0.46, 0.35, 0.75)]
        case .amber: [Stop(0.85, 0.45, 0.08), Stop(1.00, 0.75, 0.25), Stop(0.70, 0.30, 0.10)]
        case .citrus: [Stop(0.95, 0.60, 0.15), Stop(0.80, 0.85, 0.25), Stop(0.30, 0.65, 0.30)]
        case .lime: [Stop(0.40, 0.68, 0.15), Stop(0.75, 0.92, 0.35), Stop(0.20, 0.55, 0.30)]
        case .lagoon: [Stop(0.05, 0.55, 0.65), Stop(0.25, 0.90, 0.88), Stop(0.08, 0.42, 0.70)]
        case .sky: [Stop(0.25, 0.55, 0.92), Stop(0.60, 0.82, 1.00), Stop(0.30, 0.48, 0.88)]
        case .violet: [Stop(0.42, 0.18, 0.75), Stop(0.70, 0.45, 1.00), Stop(0.32, 0.15, 0.65)]
        case .orchid: [Stop(0.70, 0.30, 0.75), Stop(0.95, 0.62, 0.92), Stop(0.55, 0.25, 0.70)]
        case .forest: [Stop(0.08, 0.24, 0.18), Stop(0.34, 0.53, 0.30), Stop(0.14, 0.34, 0.39)]
        case .jade: [Stop(0.08, 0.55, 0.45), Stop(0.35, 0.85, 0.68), Stop(0.10, 0.42, 0.48)]
        case .aurora: [Stop(0.08, 0.40, 0.50), Stop(0.30, 0.95, 0.65), Stop(0.50, 0.28, 0.78)]
        case .ocean: [Stop(0.04, 0.26, 0.50), Stop(0.08, 0.60, 0.66), Stop(0.14, 0.30, 0.62)]
        case .cobalt: [Stop(0.10, 0.25, 0.75), Stop(0.30, 0.55, 1.00), Stop(0.12, 0.18, 0.62)]
        case .midnight: [Stop(0.08, 0.12, 0.35), Stop(0.25, 0.35, 0.70), Stop(0.12, 0.10, 0.38)]
        case .dusk: [Stop(0.18, 0.16, 0.39), Stop(0.47, 0.29, 0.60), Stop(0.73, 0.37, 0.47)]
        case .nebula: [Stop(0.25, 0.15, 0.60), Stop(0.95, 0.40, 0.75), Stop(0.18, 0.40, 0.78)]
        case .twilight: [Stop(0.20, 0.28, 0.65), Stop(1.00, 0.60, 0.50), Stop(0.50, 0.25, 0.62)]
        case .plum: [Stop(0.50, 0.18, 0.45), Stop(0.78, 0.42, 0.70), Stop(0.38, 0.15, 0.42)]
        case .pearl: [Stop(0.90, 0.89, 0.87), Stop(0.97, 0.96, 0.94), Stop(0.84, 0.84, 0.86)]
        case .fog: [Stop(0.78, 0.82, 0.86), Stop(0.90, 0.92, 0.95), Stop(0.70, 0.74, 0.80)]
        case .sand: [Stop(0.78, 0.70, 0.56), Stop(0.95, 0.88, 0.75), Stop(0.65, 0.56, 0.45)]
        case .stone: [Stop(0.70, 0.68, 0.64), Stop(0.84, 0.82, 0.78), Stop(0.60, 0.60, 0.62)]
        case .sage: [Stop(0.62, 0.70, 0.60), Stop(0.80, 0.86, 0.76), Stop(0.55, 0.62, 0.58)]
        case .taupe: [Stop(0.62, 0.54, 0.50), Stop(0.78, 0.70, 0.66), Stop(0.52, 0.46, 0.46)]
        case .mocha: [Stop(0.48, 0.32, 0.24), Stop(0.72, 0.55, 0.42), Stop(0.38, 0.24, 0.18)]
        case .slate: [Stop(0.35, 0.42, 0.52), Stop(0.58, 0.66, 0.75), Stop(0.28, 0.34, 0.44)]
        case .storm: [Stop(0.38, 0.44, 0.55), Stop(0.66, 0.72, 0.82), Stop(0.42, 0.38, 0.50)]
        case .graphite: [Stop(0.22, 0.22, 0.24), Stop(0.45, 0.45, 0.48), Stop(0.15, 0.15, 0.17)]
        }
    }
}

#if canImport(SwiftUI)
/// A preset as the Mac and iPhone draw it: a diagonal gradient with a soft glow of its middle colour.
public struct PresetGradient: View {
    let preset: ConversationBackgroundPreset
    public init(_ preset: ConversationBackgroundPreset) { self.preset = preset }

    public var body: some View {
        let colors = preset.stops.map(\.color)
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(colors[1].opacity(0.5))
                    .frame(width: geometry.size.width * 1.4, height: geometry.size.height * 1.1)
                    .rotationEffect(.degrees(-35)).offset(x: geometry.size.width * 0.35)
                    .blur(radius: 50)
            }
        }
    }
}
#endif

public enum BackgroundMediaKind: String, Codable, Sendable {
    case image, video, dynamicImage
}

/// Local appearance only: kept out of message delivery and the agent workspace.
public struct ConversationBackground: Codable, Equatable, Sendable {
    public var preset: ConversationBackgroundPreset?
    public var imageFilename: String?
    public var mediaKind: BackgroundMediaKind?
    public init(preset: ConversationBackgroundPreset? = nil, imageFilename: String? = nil, mediaKind: BackgroundMediaKind? = nil) {
        self.preset = preset
        self.imageFilename = imageFilename
        self.mediaKind = mediaKind
    }
    public var isDefault: Bool { preset == nil && imageFilename == nil }

    private enum CodingKeys: String, CodingKey { case preset, imageFilename, mediaKind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decodeIfPresent(String.self, forKey: .preset).flatMap(ConversationBackgroundPreset.init(rawValue:))
        imageFilename = try container.decodeIfPresent(String.self, forKey: .imageFilename)
        mediaKind = try container.decodeIfPresent(BackgroundMediaKind.self, forKey: .mediaKind)
    }

    #if canImport(ImageIO)
    public static func canUseImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return isImageSource(source)
    }

    public static func isImageSource(_ source: CGImageSource) -> Bool {
        // ImageIO can create a source for arbitrary text without recognizing an image.
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
    #endif
}

public enum ConversationBackgroundError: LocalizedError {
    case invalidImage
    case invalidMedia
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "Choose a readable image smaller than 50 MB."
        case .invalidMedia: return "Choose a readable image or HEIC up to 512 MB, or a playable MP4, M4V or MOV video up to 1 GB. Wallpaper packages and streaming playlists are not supported."
        }
    }
}
