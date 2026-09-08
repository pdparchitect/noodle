import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AttachmentTransferPayload: Sendable {
    case file(URL)
    case data(Data, originalFilename: String, mediaType: String)
}

public enum AttachmentTransferError: LocalizedError {
    case unsupportedItem
    case invalidRemoteResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedItem:
            return "The copied or dropped item does not contain an attachment."
        case .invalidRemoteResponse:
            return "The browser attachment could not be downloaded."
        }
    }
}

public enum AttachmentTransfer {
    public static func photoPayload(_ data: Data) throws -> AttachmentTransferPayload {
        guard data.count <= 50 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image),
              CGImageSourceGetCount(source) > 0 else { throw ConversationBackgroundError.invalidImage }
        return .data(data, originalFilename: "Photo.\(type.preferredFilenameExtension ?? "image")",
                     mediaType: type.preferredMIMEType ?? "application/octet-stream")
    }

    public static let dropContentTypes: [UTType] = [
        .fileURL,
        .image,
        .pdf,
        .movie,
        .audio,
        .archive,
        .url,
        .data
    ]

    // Plain text is intentionally excluded so Command-V continues to paste text
    // into the composer rather than turning it into an attachment.
    public static let pasteContentTypes: [UTType] = [
        .fileURL,
        .image,
        .pdf,
        .movie,
        .audio,
        .archive
    ]

    public static func load(_ provider: NSItemProvider) async throws -> AttachmentTransferPayload {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await loadURL(from: provider),
           url.isFileURL {
            return .file(url.standardizedFileURL)
        }

        if let contentType = preferredDataType(from: provider) {
            let data = try await loadData(from: provider, contentType: contentType)
            return .data(
                data,
                originalFilename: filename(for: provider, contentType: contentType),
                mediaType: contentType.preferredMIMEType ?? "application/octet-stream"
            )
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(from: provider)
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw AttachmentTransferError.unsupportedItem
            }
            return try await loadRemoteURL(url)
        }

        throw AttachmentTransferError.unsupportedItem
    }

    private static func preferredDataType(from provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .filter { contentType in
                !contentType.conforms(to: .fileURL) &&
                    !contentType.conforms(to: .url) &&
                    !contentType.conforms(to: .text) &&
                    !contentType.conforms(to: .html) &&
                    !contentType.conforms(to: .directory) &&
                    contentType.conforms(to: .data)
            }
            .min { typePriority($0) < typePriority($1) }
    }

    private static func typePriority(_ contentType: UTType) -> Int {
        if contentType == .png { return 0 }
        if contentType == .jpeg { return 1 }
        if contentType.conforms(to: .image) { return 2 }
        if contentType.conforms(to: .pdf) { return 3 }
        if contentType.conforms(to: .movie) { return 4 }
        if contentType.conforms(to: .audio) { return 5 }
        if contentType.conforms(to: .archive) { return 6 }
        return 7
    }

    private static func loadURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = object as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AttachmentTransferError.unsupportedItem)
                }
            }
        }
    }

    private static func loadData(
        from provider: NSItemProvider,
        contentType: UTType
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: contentType) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: AttachmentTransferError.unsupportedItem)
                }
            }
        }
    }

    private static func loadRemoteURL(_ url: URL) async throws -> AttachmentTransferPayload {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw AttachmentTransferError.invalidRemoteResponse
        }

        let contentType = response.mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: url.pathExtension)
            ?? .data
        return .data(
            data,
            originalFilename: normalizedFilename(
                response.suggestedFilename ?? url.lastPathComponent,
                contentType: contentType
            ),
            mediaType: response.mimeType ?? contentType.preferredMIMEType ?? "application/octet-stream"
        )
    }

    private static func filename(for provider: NSItemProvider, contentType: UTType) -> String {
        let fallback: String
        if contentType.conforms(to: .image) {
            fallback = "Pasted Image"
        } else {
            fallback = "Attachment"
        }
        return normalizedFilename(provider.suggestedName ?? fallback, contentType: contentType)
    }

    private static func normalizedFilename(_ proposedName: String, contentType: UTType) -> String {
        var filename = URL(fileURLWithPath: proposedName).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if filename.isEmpty {
            filename = contentType.conforms(to: .image) ? "Pasted Image" : "Attachment"
        }
        if URL(fileURLWithPath: filename).pathExtension.isEmpty,
           let suffix = contentType.preferredFilenameExtension {
            filename += ".\(suffix)"
        }
        return filename
    }
}
