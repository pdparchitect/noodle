import Foundation

public struct TransferProgress: Sendable {
    public let received: Int64
    public let expected: Int64
    public let elapsed: TimeInterval

    public init(received: Int64, expected: Int64, elapsed: TimeInterval) {
        self.received = max(0, received)
        self.expected = expected
        self.elapsed = max(0, elapsed)
    }

    public var fraction: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }

    public var detail: String {
        let bytes = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let total =
            expected > 0
            ? " of " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file) : " downloaded"
        guard elapsed >= 1, received > 0 else { return bytes + total }
        let rate = ByteCountFormatter.string(fromByteCount: Int64(Double(received) / elapsed), countStyle: .file)
        return bytes + total + " · " + rate + "/s"
    }
}

/// Single-use delegate-backed download. The caller owns a successful result file.
/// Reporting is throttled so a fast transfer cannot flood the main actor.
public final class DownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (TransferProgress) -> Void
    private let started = Date()
    private let lock = NSLock()
    private var lastReport = Date.distantPast
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var used = false

    public init(report: @escaping @Sendable (TransferProgress) -> Void) { self.report = report }

    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in start(request, continuation: continuation) }
        } onCancel: { self.cancel() }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: result.0)
            throw URLError(.cancelled)
        }
        return result
    }

    private func start(_ request: URLRequest, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        guard !cancelled, !used else {
            lock.unlock()
            continuation.resume(throwing: URLError(.cancelled))
            return
        }
        used = true
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        let cancelled = cancelled
        lock.unlock()
        session?.invalidateAndCancel()
        if cancelled {
            if case .success(let download) = result { try? FileManager.default.removeItem(at: download.0) }
            continuation.resume(throwing: URLError(.cancelled))
        } else {
            continuation.resume(with: result)
        }
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()
        lock.lock()
        let shouldReport = now.timeIntervalSince(lastReport) >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite
        if shouldReport { lastReport = now }
        lock.unlock()
        if shouldReport {
            report(
                TransferProgress(
                    received: totalBytesWritten, expected: totalBytesExpectedToWrite,
                    elapsed: now.timeIntervalSince(started)))
        }
    }

    public func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleRestore-\(UUID().uuidString).download")
            try FileManager.default.moveItem(at: location, to: saved)
            finish(.success((saved, response)))
        } catch { finish(.failure(error)) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
