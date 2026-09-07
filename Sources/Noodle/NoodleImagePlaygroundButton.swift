import AppKit
import ImagePlayground
import SwiftUI

@available(macOS 15.1, *)
struct NoodleImagePlaygroundButton: View {
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var isPresented = false

    let sourceImageData: Data?
    let onCompletion: (URL) -> Void

    var body: some View {
        if supportsImagePlayground {
            configuredButton
        }
    }

    @ViewBuilder
    private var configuredButton: some View {
        if #available(macOS 26.4, *) {
            triggerButton
                .imagePlaygroundSheet(
                    isPresented: $isPresented,
                    sourceImage: sourceImage,
                    onCompletion: onCompletion
                )
                .imagePlaygroundPersonalizationPolicy(.disabled)
                .imagePlaygroundOptions(imagePlaygroundOptions)
                .imagePlaygroundGenerationStyle(.illustration)
        } else if #available(macOS 15.4, *) {
            triggerButton
                .imagePlaygroundSheet(
                    isPresented: $isPresented,
                    sourceImage: sourceImage,
                    onCompletion: onCompletion
                )
                .imagePlaygroundPersonalizationPolicy(.disabled)
                .imagePlaygroundGenerationStyle(.illustration)
        } else {
            triggerButton
                .imagePlaygroundSheet(
                    isPresented: $isPresented,
                    sourceImage: sourceImage,
                    onCompletion: onCompletion
                )
        }
    }

    private var triggerButton: some View {
        Button {
            isPresented = true
        } label: {
            Label("Create Image…", systemImage: "apple.intelligence")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    @available(macOS 26.4, *)
    private var imagePlaygroundOptions: ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        options.personalization = .disabled
        return options
    }

    private var sourceImage: Image? {
        guard let sourceImageData, let image = NSImage(data: sourceImageData) else { return nil }
        return Image(nsImage: image)
    }
}
