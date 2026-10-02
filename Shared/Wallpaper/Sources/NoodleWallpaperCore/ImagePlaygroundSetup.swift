#if canImport(ImagePlayground)
import ImagePlayground
import SwiftUI

extension View {
    /// How every Image Playground sheet in Noodle opens, on the Mac and the phone alike:
    /// on Illustration, never offering people from Photos, and, for a background, in
    /// the shape of the screen it fills rather than a square.
    @ViewBuilder public func noodleImagePlayground(shapedLike size: CGSize? = nil) -> some View {
        if #available(macOS 27, iOS 27, *) {
            imagePlaygroundOptions(Self.imagePlaygroundOptions(shapedLike: size))
                .imagePlaygroundGenerationStyle(.illustration)
        } else if #available(macOS 26.4, iOS 26.4, *) {
            imagePlaygroundOptions(Self.imagePlaygroundOptions(shapedLike: nil))
                .imagePlaygroundGenerationStyle(.illustration)
        } else if #available(macOS 15.4, iOS 18.4, *) {
            imagePlaygroundPersonalizationPolicy(.disabled)
                .imagePlaygroundGenerationStyle(.illustration)
        } else {
            self
        }
    }

    @available(macOS 26.4, iOS 26.4, *)
    private static func imagePlaygroundOptions(shapedLike size: CGSize?) -> ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        options.personalization = .disabled
        #if canImport(ImagePlayground, _version: 198)
        if #available(macOS 27, iOS 27, *), let size, size.width > 0, size.height > 0 {
            options.sizeSpecification = .closest(to: size)
        }
        #endif
        return options
    }
}
#endif
