import Foundation
import NoodleCore

@MainActor final class HarnessVersionChecker: HarnessVersionChecking {
    private let inspect: @MainActor (HarnessInstallation) async throws -> HarnessVersionReport
    private let fetch: @MainActor (URL) async throws -> Data
    private let now: @MainActor () -> Date
    init(inspect: (@MainActor (HarnessInstallation) async throws -> HarnessVersionReport)? = nil,
         fetch: (@MainActor (URL) async throws -> Data)? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.inspect = inspect ?? { installation in
            if installation.provider == .apple {
                let result = try await AppleHostProbe.load()
                return HarnessVersionReport(installedVersion: result.version)
            }
            return try await HarnessVersionHostProbe.load(installation)
        }
        self.fetch = fetch ?? { try await Self.fetchRelease($0) }
        self.now = now
    }
    func check(_ installation: HarnessInstallation, previous: HarnessVersionReport?, forceLatest: Bool) async throws -> HarnessVersionReport {
        var report = try await inspect(installation)
        try Task.checkCancellation()
        if installation.provider == .apple { return report }
        report.latestVersion = previous?.latestVersion
        report.latestCheckedAt = previous?.latestCheckedAt
        guard let url = HarnessVersionPolicy.latestURL(for: installation) else {
            report.latestVersion = nil
            report.latestCheckedAt = nil
            return report
        }
        if !forceLatest, let date = previous?.latestCheckedAt,
           (0..<6 * 60 * 60).contains(now().timeIntervalSince(date)) { return report }
        do {
            let data = try await fetch(url)
            try Task.checkCancellation()
            guard let version = HarnessVersionPolicy.latestVersion(provider: installation.provider, data: data) else {
                throw HarnessSetupError("The provider returned an unrecognized release version.")
            }
            report.latestVersion = version
            report.latestCheckedAt = now()
        } catch is CancellationError { throw CancellationError() }
        catch { report.checkError = "Could not check the latest release. Your installation and sign-in are unchanged; try Check Again." }
        return report
    }

    nonisolated static let maximumReleaseBytes = 2 * 1_024 * 1_024

    nonisolated static func fetchRelease(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        let config = configuration
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: ReleaseRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Noodle-Harness-Version-Check", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximumReleaseBytes else { throw HarnessSetupError("Release check unavailable.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumReleaseBytes else { throw HarnessSetupError("Release response too large.") }
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

@MainActor private enum HarnessVersionHostProbe {
    static func load(_ installation: HarnessInstallation) async throws -> HarnessVersionReport {
        guard let path = installation.executablePath else { throw HarnessSetupError("Install the harness first.") }
        return try await AgentHostRequest().load(timeout: .seconds(20), noReply: "No version information was returned.",
            timedOut: "Harness version check timed out.", disconnected: "Could not inspect the harness version.") {
            $0.inspectHarnessVersion(provider: installation.provider, executablePath: path, reply: $1)
        }
    }
}
