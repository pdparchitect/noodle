import AppKit
import ImagePlayground
import NoodleWallpaperCore
import SwiftUI

@available(macOS 15.1, *)
public struct NoodleImagePlaygroundButton: View {
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State private var isPresented = false
    let sourceImageData: Data?
    let concepts: [ImagePlaygroundConcept]
    let shape: CGSize?
    let onCompletion: (URL) -> Void

    /// `shape` is the screen a background fills; pictures leave it out and stay square.
    public init(sourceImageData: Data?, concepts: [ImagePlaygroundConcept] = [], shape: CGSize? = nil,
                onCompletion: @escaping (URL) -> Void) {
        self.sourceImageData = sourceImageData
        self.concepts = concepts
        self.shape = shape
        self.onCompletion = onCompletion
    }

    public var body: some View {
        if supportsImagePlayground {
            triggerButton
                .imagePlaygroundSheet(isPresented: $isPresented, concepts: concepts, sourceImage: sourceImage, onCompletion: onCompletion)
                .noodleImagePlayground(shapedLike: shape)
        }
    }
    private var triggerButton: some View {
        Button { isPresented = true } label: {
            Label("Create Image…", systemImage: "apple.intelligence").frame(maxWidth: .infinity)
                .frame(height: 20)
        }.buttonStyle(.bordered)
    }
    private var sourceImage: Image? {
        guard let sourceImageData, let image = NSImage(data: sourceImageData) else { return nil }
        return Image(nsImage: image)
    }
}
