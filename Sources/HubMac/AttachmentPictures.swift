import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Small pictures of conversation files for devices: a picture scaled down, a video's first frame or
/// a PDF's first page, as JPEG, or PNG where the picture is see-through.
enum AttachmentPictures {
    static func make(of file: URL, mediaType: String, pixels: Int) async -> Data? {
        let image: CGImage?
        if mediaType.hasPrefix("image/") {
            image = picture(file, pixels: pixels)
        } else if mediaType.hasPrefix("video/") {
            image = await frame(file, pixels: pixels)
        } else if mediaType == "application/pdf" {
            image = page(file, pixels: pixels)
        } else {
            return nil
        }
        return image.flatMap(encoded)
    }

    private static func picture(_ file: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    private static func frame(_ file: URL, pixels: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        return try? await generator.image(at: .zero).image
    }

    private static func page(_ file: URL, pixels: Int) -> CGImage? {
        guard let page = CGPDFDocument(file as CFURL)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(box.width, box.height)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func encoded(_ image: CGImage) -> Data? {
        let seeThrough = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (seeThrough ? "public.png" : "public.jpeg") as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
