import CoreGraphics
import NoodleWallpaperCore
import QuickLookThumbnailing

/// A Metal shader file's thumbnail: a still of what it draws.
@objc(ShaderThumbnailProvider)
final class ShaderThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // Landscape, as a background is on a Mac.
        let side = max(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side, height: (side * 0.625).rounded())
        let pixels = (width: max(1, Int(size.width * request.scale)), height: max(1, Int(size.height * request.scale)))
        let url = request.fileURL, scale = Float(request.scale)
        // Quick Look takes the reply on any thread.
        nonisolated(unsafe) let handler = handler
        Task {
            do {
                let image = try await ShaderPipeline.still(of: url, width: pixels.width, height: pixels.height, scale: scale)
                handler(QLThumbnailReply(contextSize: size) { context in
                    context.draw(image, in: CGRect(origin: .zero, size: size))
                    return true
                }, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
