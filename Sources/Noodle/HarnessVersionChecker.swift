import Foundation
import NoodleCore

@MainActor final class HarnessVersionChecker: HarnessVersionChecking {
    func check(_ installation: HarnessInstallation, previous: HarnessVersionReport?, forceLatest: Bool) async throws -> HarnessVersionReport {
        if installation.provider == .apple {
            let result = try await AppleHostProbe().load()
            return HarnessVersionReport(installedVersion: result.version)
        }
        var report = try await HarnessVersionHostProbe().load(installation)
        report.latestVersion = previous?.latestVersion
        report.latestCheckedAt = previous?.latestCheckedAt
        guard let url = HarnessVersionPolicy.latestURL(for: installation) else {
            report.latestVersion = nil
            report.latestCheckedAt = nil
            return report
        }
        if !forceLatest, let date = previous?.latestCheckedAt,
           (0..<6 * 60 * 60).contains(Date().timeIntervalSince(date)) { return report }
        do {
            let data = try await Self.fetchRelease(url)
            guard let version = HarnessVersionPolicy.latestVersion(provider: installation.provider, data: data) else {
                throw HarnessSetupError("The provider returned an unrecognized release version.")
            }
            report.latestVersion = version
            report.latestCheckedAt = Date()
        } catch is CancellationError { throw CancellationError() }
        catch { report.checkError = "Could not check the latest release. Your installation and sign-in are unchanged; try Check Again." }
        return report
    }

    private static func fetchRelease(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: ReleaseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Noodle-Harness-Version-Check", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 262_144 else { throw HarnessSetupError("Release check unavailable.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 262_144 else { throw HarnessSetupError("Release response too large.") }
            data.append(byte)
        }
        return data
    }
}

private final class ReleaseRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
        completionHandler(allowed ? request : nil)
    }
}

@MainActor private final class HarnessVersionHostProbe {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<HarnessVersionReport, Error>?
    private var timeout: Task<Void, Never>?
    init() throws { connection = try ExtendedAgentConnection() }

    func load(_ installation: HarnessInstallation) async throws -> HarnessVersionReport {
        guard let path = installation.executablePath else { throw HarnessSetupError("Install the harness first.") }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.onFailure = { [weak self] _ in
                    Task { @MainActor in self?.finish(.failure(HarnessSetupError("Could not inspect the harness version."))) }
                }
                connection.inspectHarnessVersion(provider: installation.provider, executablePath: path) { [weak self] data, error in
                    Task { @MainActor in
                        do {
                            if let error { throw HarnessSetupError(error) }
                            guard let data else { throw HarnessSetupError("No version information was returned.") }
                            self?.finish(.success(try JSONDecoder().decode(HarnessVersionReport.self, from: data)))
                        } catch { self?.finish(.failure(error)) }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(HarnessSetupError("Harness version check timed out.")))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }

    private func finish(_ result: Result<HarnessVersionReport, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
