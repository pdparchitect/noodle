import AppKit
import ComputerDocument
import QuickLookThumbnailing

@main enum ThumbnailEntry { static func main() {} }

@objc(ComputerReferenceThumbnailProvider)
final class ComputerReferenceThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let card = try ComputerReferenceDocument.read(request.fileURL)
            DispatchQueue.main.async {
                let size = NSSize(width: 800, height: 520)
                let view = ComputerDocumentView(card: card, size: size)
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    handler(nil, CocoaError(.fileReadCorruptFile)); return
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { handler(nil, CocoaError(.fileReadCorruptFile)); return }
                let scale = min(request.maximumSize.width / size.width, request.maximumSize.height / size.height)
                let target = NSSize(width: size.width * scale, height: size.height * scale)
                handler(QLThumbnailReply(contextSize: target, drawing: { context in
                    context.draw(image, in: NSRect(origin: .zero, size: target)); return true
                }), nil)
            }
        } catch { handler(nil, error) }
    }
}
