import CryptoKit
import Foundation

public struct AppleModelDownloadProgress: Sendable {
    public enum Phase: Sendable { case downloading, verifying, importing }
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public var fraction: Double { min(1, Double(completedBytes) / Double(max(1, totalBytes))) }
}

/// The app downloads data into private staging storage. The offline bot helper
/// only sees a model after checksum verification and the normal import checks.
public struct AppleModelDownloader: Sendable {
    typealias Fetch = @Sendable (URL, URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> Void
    private let fetch: Fetch

    public init() {
        fetch = { url, destination, byteCount, progress in
            try await Self.fetchResource(url, destination: destination, byteCount: byteCount, progress: progress)
        }
    }
    init(fetch: @escaping Fetch) { self.fetch = fetch }

    public func download(_ downloadable: AppleDownloadableModel, into store: AppleLocalModelStore,
                         progress: @escaping @Sendable (AppleModelDownloadProgress) -> Void = { _ in }) async throws -> AppleLocalModel {
        try Task.checkCancellation()
        if let existing = try store.models().first(where: { $0.sourceRepository == downloadable.repository }) {
            return existing
        }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        // Partial weights from an interrupted run must not count against this download.
        store.removeAbandonedStaging()
        let capacity = try store.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = capacity.volumeAvailableCapacityForImportantUsage,
           available < downloadable.byteCount * 2 + 64 * 1_024 * 1_024 {
            throw HarnessSetupError("Not enough disk space to download and import this model.")
        }
        let staging = try store.beginStaging(AppleLocalModelStore.downloadStaging)
        defer { store.endStaging(staging) }
        let source = staging.appendingPathComponent(downloadable.sourceURL.lastPathComponent)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for file in downloadable.files {
            try Task.checkCancellation()
            guard !file.name.hasPrefix("."), !file.name.contains("/"),
                  ["json", "safetensors", "model", "txt", "jinja"].contains((file.name as NSString).pathExtension) else {
                throw HarnessSetupError("The model download contains an invalid resource.")
            }
            let url = downloadable.sourceURL.appendingPathComponent("resolve")
                .appendingPathComponent(downloadable.revision).appendingPathComponent(file.name)
            let destination = source.appendingPathComponent(file.name)
            let previous = completed
            progress(.init(phase: .downloading, completedBytes: previous, totalBytes: downloadable.byteCount))
            try await fetch(url, destination, file.byteCount) { received in
                progress(.init(phase: .downloading, completedBytes: previous + min(file.byteCount, max(0, received)),
                               totalBytes: downloadable.byteCount))
            }
            progress(.init(phase: .verifying, completedBytes: previous + file.byteCount, totalBytes: downloadable.byteCount))
            try Self.verify(destination, file: file)
            completed += file.byteCount
        }
        try Task.checkCancellation()
        // Another settings window may have completed the same download.
        if let existing = try store.models().first(where: { $0.sourceRepository == downloadable.repository }) {
            return existing
        }
        progress(.init(phase: .importing, completedBytes: completed, totalBytes: downloadable.byteCount))
        return try store.importModel(from: source, sourceRepository: downloadable.repository)
    }

    static func verify(_ url: URL, file: AppleDownloadableModel.File) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == file.byteCount else {
            throw HarnessSetupError("Incomplete model file: \(file.name). Download the model again.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func checksum<H: HashFunction>(_ initial: H) throws -> String {
            var hash = initial
            while true {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let actual: String
        let expected: String
        switch file.digest {
        case .sha256(let digest):
            expected = digest
            actual = try checksum(SHA256())
        case .gitSHA1(let digest):
            // Hugging Face publishes Git blob IDs for small, non-LFS files.
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(file.byteCount)\0".utf8))
            expected = digest
            actual = try checksum(hash)
        }
        guard actual == expected else {
            throw HarnessSetupError("Model file verification failed: \(file.name). Download the model again.")
        }
    }

    static func fetchResource(_ url: URL, destination: URL, byteCount: Int64,
                              progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard ModelDownloadDelegate.allows(url) else { throw HarnessSetupError("Invalid model download URL.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let (completion, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let delegate = ModelDownloadDelegate(destination: destination, byteCount: byteCount,
                                             progress: progress, completion: continuation)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // The async download convenience API bypasses download progress methods.
        // Use a delegate task and bridge its completion into structured concurrency.
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            task.resume()
            for try await _ in completion {}
            try Task.checkCancellation()
        } onCancel: { task.cancel() }
    }
}

final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let byteCount: Int64
    private let progress: @Sendable (Int64) -> Void
    private let completion: AsyncThrowingStream<Void, Error>.Continuation
    init(destination: URL, byteCount: Int64, progress: @escaping @Sendable (Int64) -> Void,
         completion: AsyncThrowingStream<Void, Error>.Continuation) {
        self.destination = destination
        self.byteCount = byteCount
        self.progress = progress
        self.completion = completion
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > byteCount || totalBytesExpectedToWrite > byteCount {
            completion.finish(throwing: HarnessSetupError("The model download exceeded its expected size."))
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw HarnessSetupError("The model download failed. Try again when Hugging Face is available.")
            }
            // URLSession owns this file only for the duration of the callback.
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { completion.finish(throwing: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion.finish(throwing: error) }
        else { completion.finish() }
    }
}
