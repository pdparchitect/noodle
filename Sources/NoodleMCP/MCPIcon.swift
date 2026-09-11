import Foundation
import ImageIO
import UniformTypeIdentifiers
import MCP
import NoodleCore

/// Optional metadata artwork. No HTML scraping, SVG execution, or authenticated
/// third-party image requests. Missing/unsupported artwork uses a system symbol.
enum MCPIcon {
    static func load(_ icons: [Icon], endpoint: URL,
                     sessionConfiguration: () -> URLSessionConfiguration = { .ephemeral }) async -> Data? {
        for icon in icons.prefix(3) {
            let data: Data?
            if icon.src.hasPrefix("data:image/png;base64,") || icon.src.hasPrefix("data:image/jpeg;base64,") {
                guard icon.src.utf8.count <= 180_000, let comma = icon.src.firstIndex(of: ",") else { continue }
                data = Data(base64Encoded: String(icon.src[icon.src.index(after: comma)...]))
            } else if let url = URL(string: icon.src), url.host == endpoint.host, url.port == endpoint.port,
                      (try? MCPConnectionRecord.validatedEndpoint(url)) != nil {
                let configuration = sessionConfiguration()
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 3
                configuration.timeoutIntervalForResource = 3
                let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    var buffer = Data()
                    for try await byte in bytes {
                        guard buffer.count < 131_072 else { throw MCPServiceError.responseTooLarge }
                        buffer.append(byte)
                    }
                    data = buffer
                } catch { continue }
            } else { continue }
            if let data, let normalized = thumbnail(data) { return normalized }
        }
        return nil
    }
    static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= 131_072,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.ico.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
