import Foundation
import UniformTypeIdentifiers

/// Resolve browser and Finder drops into the same owned media used by the picker.
public enum BackgroundDrop {
    public static let contentTypes: [UTType] = [.fileURL, .image, .movie, .url]
    static let maximumBytes: Int64 = 1_073_741_824

    public static func accepts(_ provider: NSItemProvider) -> Bool {
        contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    public static func load(_ provider: NSItemProvider, configuration: URLSessionConfiguration = .ephemeral) async throws -> PreparedBackgroundFile {
        try Task.checkCancellation()
        var failure: Error = ConversationBackgroundError.invalidMedia
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            do {
                let url = try await loadURL(provider)
                guard url.isFileURL else { throw ConversationBackgroundError.invalidMedia }
                return try await PreparedBackgroundFile.prepare(url)
            } catch { failure = error }
        }

        // Prefer the actual media over a browser's page link or HTML fallback.
        // Videos come before images so a poster cannot replace a dropped movie.
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            .filter { $0.conforms(to: .image) || $0.conforms(to: .movie) }
            .sorted { priority($0) < priority($1) }
        for type in types {
            try Task.checkCancellation()
            do { return try await loadMedia(provider, type: type) }
            catch { failure = error }
        }
        try Task.checkCancellation()
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(provider)
            if url.isFileURL { return try await PreparedBackgroundFile.prepare(url) }
            return try await loadRemote(url, configuration: configuration)
        }
        throw failure
    }

    private static func priority(_ type: UTType) -> Int {
        if type.conforms(to: .movie) { return 0 }
        if type == .tiff { return 2 }
        return 1
    }

    private static func loadURL(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { value, error in
                if let url = value as? URL { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? ConversationBackgroundError.invalidMedia) }
            }
        }
    }

    private static func loadMedia(_ provider: NSItemProvider, type: UTType) async throws -> PreparedBackgroundFile {
        let directory = try stagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suffix = type.preferredFilenameExtension
            ?? URL(fileURLWithPath: provider.suggestedName ?? "").pathExtension
        let target = directory.appendingPathComponent("media").appendingPathExtension(suffix)
        do {
            let _: Void = try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    do {
                        guard error == nil, let url else { throw BackgroundDropError.noFileRepresentation }
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try checkSize(url)
                        // The provider deletes its file when this callback returns.
                        try FileManager.default.copyItem(at: url, to: target)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } catch BackgroundDropError.noFileRepresentation {
            try Task.checkCancellation()
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? ConversationBackgroundError.invalidMedia) }
                }
            }
            guard !data.isEmpty, data.count <= maximumBytes else { throw ConversationBackgroundError.invalidMedia }
            try data.write(to: target, options: .atomic)
        }
        try Task.checkCancellation()
        return try await PreparedBackgroundFile.prepare(target)
    }

    static func loadRemote(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> PreparedBackgroundFile {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw BackgroundDropError.directMediaRequired
        }
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (download, response) = try await session.download(from: url, delegate: BackgroundDownloadLimit())
        defer { try? FileManager.default.removeItem(at: download) }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw BackgroundDropError.downloadFailed
        }
        guard response.expectedContentLength <= maximumBytes else { throw ConversationBackgroundError.invalidMedia }
        try checkSize(download)
        let directory = try stagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Download URLs have no useful extension. Recover it from the response,
        // including media endpoints whose URL has no filename at all.
        let type = response.mimeType.flatMap { UTType(mimeType: $0) }
        let mediaType = type.flatMap { $0.conforms(to: .image) || $0.conforms(to: .movie) ? $0 : nil }
        let filenameExtensions = [response.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension },
                                  response.url?.pathExtension, url.pathExtension].compactMap { $0 }
        let suffix = mediaType?.preferredFilenameExtension ?? filenameExtensions.first(where: {
            guard let type = UTType(filenameExtension: $0) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }) ?? "media"
        let target = directory.appendingPathComponent("media").appendingPathExtension(suffix)
        try FileManager.default.moveItem(at: download, to: target)
        try Task.checkCancellation()
        do { return try await PreparedBackgroundFile.prepare(target) }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackgroundDropError.directMediaRequired }
    }

    private static func stagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-background-drop-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func checkSize(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw ConversationBackgroundError.invalidMedia
        }
    }
}

private enum BackgroundDropError: LocalizedError {
    case directMediaRequired, downloadFailed, noFileRepresentation
    var errorDescription: String? {
        switch self {
        case .directMediaRequired, .noFileRepresentation: return "Drop a readable image or MP4, M4V or MOV video, or a direct link to one."
        case .downloadFailed: return "The background couldn’t be downloaded. Try dropping the image or video itself."
        }
    }
}

private final class BackgroundDownloadLimit: NSObject, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > BackgroundDrop.maximumBytes || totalBytesExpectedToWrite > BackgroundDrop.maximumBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
