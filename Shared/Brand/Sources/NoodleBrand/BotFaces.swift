import Foundation

/// Who a face, or a name, reads as.
public enum BotFacePresentation: Sendable {
    case feminine, masculine
}

/// A drawn face a bot can wear. Bots keep a copy of the picture, so changing these never changes a bot.
public struct BotFace: Sendable, Hashable {
    /// Nil for a face that suits any name.
    public let presentation: BotFacePresentation?
    public let imageData: Data
}

public enum BotFaces {
    /// Women first, then men, then faces for any name. Each file's name says which it is.
    public static let all: [BotFace] = {
        let order = ["feminine", "masculine", "any"]
        // Foundation outside Apple's platforms hands these back as NSURL.
        let urls = (Bundle.module.urls(forResourcesWithExtension: "jpg", subdirectory: "Faces") ?? []).map { $0 as URL }.sorted {
            let kinds = [$0, $1].map { order.firstIndex(of: kind($0)) ?? order.count }
            return kinds[0] != kinds[1] ? kinds[0] < kinds[1] : $0.lastPathComponent < $1.lastPathComponent
        }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let presentation: BotFacePresentation? = switch kind(url) {
            case "feminine": .feminine
            case "masculine": .masculine
            default: nil
            }
            return BotFace(presentation: presentation, imageData: data)
        }
    }()

    /// The bundled picture of a face by its file name without the extension, such as "feminine-03".
    public static func url(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "jpg", subdirectory: "Faces")
    }

    private static func kind(_ url: URL) -> String {
        String(url.lastPathComponent.prefix { $0 != "-" })
    }

    public static func face(for imageData: Data) -> BotFace? {
        all.first { $0.imageData == imageData }
    }

    /// Whether a picture is one of these faces and suits a name of `presentation`; nil suits any face.
    public static func fits(_ imageData: Data, presentation: BotFacePresentation?) -> Bool {
        guard let face = face(for: imageData) else { return false }
        return presentation == nil || face.presentation == presentation
    }

    /// A face for a name of `presentation`, one no bot in `used` wears while any is left.
    public static func random(for presentation: BotFacePresentation?, avoiding used: Set<Data>) -> Data? {
        let fitting = all.filter { presentation == nil || $0.presentation == presentation }.map(\.imageData)
        let free = fitting.filter { !used.contains($0) }
        return (free.isEmpty ? fitting : free).randomElement()
    }

    /// `current` while it is a face that suits `presentation`, otherwise a fitting one no bot in `used` wears.
    public static func fitting(_ presentation: BotFacePresentation?, current: Data?, avoiding used: Set<Data>) -> Data? {
        if let current, fits(current, presentation: presentation) { return current }
        return random(for: presentation, avoiding: used)
    }
}
