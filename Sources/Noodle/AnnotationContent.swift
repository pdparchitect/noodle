import AppKit
import ImageIO
import NoodleCore
import UniformTypeIdentifiers
import CoreText
import PDFKit

/// Exports only annotation content. Quick Look remains the source renderer.
@MainActor enum AnnotationContent {
    static func editedData(for annotation: AttachmentAnnotation, originalURL: URL) throws -> Data {
        guard annotation.isValid else { throw WorkspaceError.invalidAttachment }
        if annotation.version == 2 {
            return annotation.region == nil ? Data(annotation.textRepresentation.utf8) : try Data(contentsOf: originalURL)
        }
        // Existing version 1 notes keep their original format. Rebuild only the
        // feedback pages and copy the original snapshot page without rerendering.
        let original = PDFDocument(url: originalURL)
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw WorkspaceError.invalidAttachment }
        let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacing = 10
        let text = NSAttributedString(string: annotation.textRepresentation, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var offset = 0
        while offset < text.length {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0),
                CGPath(rect: page.insetBy(dx: 42, dy: 48), transform: nil), nil)
            CTFrameDraw(frame, context)
            let length = CTFrameGetVisibleStringRange(frame).length
            guard length > 0 else { context.endPDFPage(); context.closePDF(); throw WorkspaceError.invalidAttachment }
            offset += length; context.endPDFPage()
        }
        if annotation.region != nil {
            guard let original, original.pageCount > 1,
                  let snapshot = original.page(at: original.pageCount - 1)?.pageRef else {
                context.closePDF(); throw WorkspaceError.invalidAttachment
            }
            context.beginPDFPage(nil); context.drawPDFPage(snapshot); context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func data(for annotation: AttachmentAnnotation, snapshot: NSImage?) throws -> Data {
        guard annotation.isValid, annotation.version == 2,
              (annotation.region == nil) == (snapshot == nil) else { throw WorkspaceError.invalidAttachment }
        guard let region = annotation.region, let snapshot else {
            return Data(annotation.textRepresentation.utf8)
        }
        guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkspaceError.invalidAttachment }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        let marked = CGRect(x: region.x * rect.width, y: region.y * rect.height,
                            width: region.width * rect.width, height: region.height * rect.height)
        let lineWidth = max(2, CGFloat(image.width) / 450)
        // A dark outer edge keeps the marker readable on light and busy images.
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.7))
        context.setLineWidth(lineWidth + 2)
        context.stroke(marked)
        context.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0, alpha: 1))
        context.setLineWidth(lineWidth)
        context.stroke(marked)
        let data = NSMutableData()
        guard let markedImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WorkspaceError.invalidAttachment
        }
        CGImageDestinationAddImage(destination, markedImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw WorkspaceError.invalidAttachment }
        return data as Data
    }
}
