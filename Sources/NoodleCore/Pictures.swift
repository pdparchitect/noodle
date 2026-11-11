import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// What a file or its bytes are, told from its contents where it matters. ImageIO knows every
/// picture the system can show; without it the common kinds are known by their signatures, and
/// media types follow file extensions from a short list.
package enum Pictures {
    /// The picture's media type, or nil when the data is not a picture.
    package static func mediaType(of data: Data) -> String? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return mediaType(of: source)
        #else
        return signedMediaType(data)
        #endif
    }

    /// The same for a file, whatever its name says.
    package static func mediaType(at url: URL) -> String? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return mediaType(of: source)
        #else
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return signedMediaType((try? handle.read(upToCount: 32)) ?? Data())
        #endif
    }

    /// Whether devices can show `data` as a picture. Without ImageIO nothing is decoded, so a
    /// picture's signature is taken at its word.
    package static func decodes(_ data: Data) -> Bool {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        #else
        return signedMediaType(data) != nil
        #endif
    }

    /// The media type a file with this extension usually has.
    package static func mediaType(forFilenameExtension pathExtension: String) -> String? {
        #if canImport(UniformTypeIdentifiers)
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType
        #else
        return extensionMediaTypes[pathExtension.lowercased()]
        #endif
    }

    /// A JPEG of the picture at most `maxPixelSize` on its longer side, turned upright. Nil
    /// for anything that is not a picture, and wherever pictures cannot be redrawn.
    package static func jpegThumbnail(at url: URL, maxPixelSize: Int) -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), mediaType(of: source) != nil, CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    private static func mediaType(of source: CGImageSource) -> String? {
        // ImageIO makes a source of any bytes; only one it recognises as a picture counts.
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image) else { return nil }
        return type.preferredMIMEType
    }
    #else
    private static func signedMediaType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(32))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if starts(Array("ftyp".utf8), at: 4), bytes.count >= 12 {
            switch String(decoding: bytes[8..<12], as: UTF8.self) {
            case "heic", "heix", "hevc", "hevx": return "image/heic"
            case "mif1", "msf1": return "image/heif"
            case "avif": return "image/avif"
            default: return nil
            }
        }
        return nil
    }

    private static let extensionMediaTypes = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
        "heic": "image/heic", "heif": "image/heif", "tif": "image/tiff", "tiff": "image/tiff", "svg": "image/svg+xml",
        "pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "html": "text/html",
        "htm": "text/html", "json": "application/json", "xml": "application/xml", "zip": "application/zip",
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "mp3": "audio/mpeg", "m4a": "audio/mp4",
        "wav": "audio/wav", "aac": "audio/aac",
    ]
    #endif
}
