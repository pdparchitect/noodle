import XCTest
@testable import NoodleCore

/// The download session's own checks, driven with tasks that are never resumed.
final class HarnessDownloadDelegateTests: XCTestCase {
    private let session = URLSession(configuration: .ephemeral)
    private let distribution = HarnessDistribution.grokBuild

    override func tearDown() { session.invalidateAndCancel() }

    private func redirect(from origin: String, to target: String, distribution: HarnessDistribution = .grokBuild) -> URL? {
        let task = session.dataTask(with: URL(string: origin)!)
        let response = HTTPURLResponse(url: URL(string: origin)!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var followed: URLRequest?
        HarnessDownloadDelegate(distribution: distribution).urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: target)!)) { followed = $0 }
        return followed?.url
    }

    func testRedirectsStayOnTheSameVendorHostOverHTTPS() throws {
        let host = try XCTUnwrap(distribution.latest.host)
        XCTAssertEqual(redirect(from: "https://\(host)/cli/latest", to: "https://\(host)/cli/grok-1.0.0"),
                       URL(string: "https://\(host)/cli/grok-1.0.0"))
        for target in ["http://\(host)/cli/grok", "https://\(host):8443/cli/grok", "https://user:pass@\(host)/cli/grok",
                       "https://example.com/cli/grok", "https://\(host).example.com/cli/grok"] {
            XCTAssertNil(redirect(from: "https://\(host)/cli/latest", to: target), target)
        }
    }

    func testRedirectToAnotherAllowedHostIsStillRefused() throws {
        let codex = HarnessDistribution.codex, hosts = codex.hosts.sorted()
        XCTAssertEqual(hosts.count, 2)
        XCTAssertNotNil(redirect(from: "https://\(hosts[0])/a", to: "https://\(hosts[0])/b", distribution: codex))
        XCTAssertNil(redirect(from: "https://\(hosts[0])/a", to: "https://\(hosts[1])/a", distribution: codex))
    }

    func testProgressIsReportedUntilTheExpectedSizeIsExceeded() async throws {
        let (completion, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let reports = Reports()
        let delegate = HarnessDownloadDelegate(distribution: distribution, byteCount: 100,
                                               progress: { reports.append($0, $1) }, completion: continuation)
        let task = session.downloadTask(with: distribution.latest)
        delegate.urlSession(session, downloadTask: task, didWriteData: 60, totalBytesWritten: 60, totalBytesExpectedToWrite: -1)
        delegate.urlSession(session, downloadTask: task, didWriteData: 40, totalBytesWritten: 100, totalBytesExpectedToWrite: 100)
        delegate.urlSession(session, downloadTask: task, didWriteData: 1, totalBytesWritten: 101, totalBytesExpectedToWrite: 100)
        XCTAssertEqual(reports.values.map(\.0), [60, 100])
        XCTAssertEqual(reports.values.map(\.1), [0, 100], "An unknown total is reported as zero")
        await assertThrows(completion, "exceeded its expected size")
        XCTAssertEqual(task.state, .canceling)
    }

    func testAFailedResponseLeavesNothingAtTheDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-download-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("download"), destination = root.appendingPathComponent("grok")
        try Data("partial".utf8).write(to: location)
        let (completion, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let delegate = HarnessDownloadDelegate(distribution: distribution, destination: destination, completion: continuation)
        delegate.urlSession(session, downloadTask: session.downloadTask(with: distribution.latest), didFinishDownloadingTo: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await assertThrows(completion, "download failed")
    }

    func testCompletionEndsTheWaitOrCarriesTheError() async throws {
        let task = session.dataTask(with: distribution.latest)
        let (done, finished) = AsyncThrowingStream<Void, Error>.makeStream()
        HarnessDownloadDelegate(distribution: distribution, completion: finished).urlSession(session, task: task, didCompleteWithError: nil)
        for try await _ in done {}
        let (failed, failure) = AsyncThrowingStream<Void, Error>.makeStream()
        HarnessDownloadDelegate(distribution: distribution, completion: failure)
            .urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        do { for try await _ in failed {}; XCTFail("The error must reach the installer") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    private func assertThrows(_ stream: AsyncThrowingStream<Void, Error>, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { for try await _ in stream {}; XCTFail("Expected an error", file: file, line: line) }
        catch { XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription, file: file, line: line) }
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(Int64, Int64)] = []
    var values: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ written: Int64, _ total: Int64) { lock.lock(); stored.append((written, total)); lock.unlock() }
}
