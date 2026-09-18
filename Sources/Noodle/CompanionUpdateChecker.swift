import Foundation
import Observation
import Sparkle

/// The newest release a companion's own Sparkle feed offers this Mac.
struct CompanionRelease: Equatable {
    /// Compared with the installed `CFBundleVersion`, as Sparkle does.
    let version: String
    let displayVersion: String
}

/// Reports whether an installed companion is behind its own update feed. The
/// companion's Sparkle updater still owns downloading and installing.
@MainActor @Observable final class CompanionUpdateChecker {
    static let shared = CompanionUpdateChecker()

    /// Installed companions that are behind their feed, as of the last refresh.
    private(set) var updates: [CompanionApp: CompanionRelease] = [:]
    @ObservationIgnored private let fetch: @MainActor (URL) async throws -> Data
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var latest: [URL: (release: CompanionRelease?, checkedAt: Date)] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(fetch: (@MainActor (URL) async throws -> Data)? = nil,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.fetch = fetch ?? { try await Self.fetchAppcast($0) }
        self.now = now
    }

    /// Replaces any refresh still in flight. Await the returned task for the result.
    @discardableResult
    func refresh(_ installations: [CompanionApp: CompanionAppInstallation], force: Bool = false) -> Task<Void, Never> {
        refreshTask?.cancel()
        let task = Task { @MainActor in
            var found: [CompanionApp: CompanionRelease] = [:]
            await withTaskGroup(of: (CompanionApp, CompanionRelease?).self) { group in
                for (app, installation) in installations {
                    group.addTask { @MainActor in (app, await self.availableUpdate(for: installation, force: force)) }
                }
                for await (app, release) in group { found[app] = release }
            }
            guard !Task.isCancelled else { return }
            if found != updates { updates = found }
        }
        refreshTask = task
        return task
    }

    func availableUpdate(for installation: CompanionAppInstallation, force: Bool) async -> CompanionRelease? {
        // A build with updates off could not install what this would announce.
        guard installation.updatesEnabled, let feed = installation.feedURL, feed.scheme == "https",
              let installed = installation.buildVersion else { return nil }
        let cached = latest[feed]
        let fresh = cached.map { (0..<6 * 60 * 60).contains(now().timeIntervalSince($0.checkedAt)) } ?? false
        var release = cached?.release
        if force || !fresh {
            // An unreachable feed keeps the last known release.
            if let data = try? await fetch(feed) {
                release = CompanionAppcast.latestRelease(in: data)
                latest[feed] = (release, now())
            }
        }
        guard let release, SUStandardVersionComparator.default
            .compareVersion(installed, toVersion: release.version) == .orderedAscending else { return nil }
        return release
    }

    nonisolated static let maximumAppcastBytes = 1_024 * 1_024

    nonisolated static func fetchAppcast(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        let config = configuration
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpShouldSetCookies = false
        // Release assets redirect to a storage host, so only the scheme is pinned.
        let session = URLSession(configuration: config, delegate: SecureRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Noodle-Companion-Update-Check", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximumAppcastBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumAppcastBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

private final class SecureRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

enum CompanionAppcast {
    /// The highest release on the default channel that this Mac can run.
    static func latestRelease(in data: Data,
                              systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                              isAppleSilicon: Bool = CompanionAppcast.isAppleSilicon) -> CompanionRelease? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        let comparator = SUStandardVersionComparator.default
        let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
        return reader.items.filter { item in
            if item["sparkle:channel"] != nil { return false }
            if let minimum = item["sparkle:minimumSystemVersion"],
               comparator.compareVersion(system, toVersion: minimum) == .orderedAscending { return false }
            if let maximum = item["sparkle:maximumSystemVersion"],
               comparator.compareVersion(system, toVersion: maximum) == .orderedDescending { return false }
            if let hardware = item["sparkle:hardwareRequirements"],
               hardware.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "arm64" }),
               !isAppleSilicon { return false }
            return true
        }.compactMap { item -> CompanionRelease? in
            guard let version = item["sparkle:version"] else { return nil }
            return CompanionRelease(version: version, displayVersion: item["sparkle:shortVersionString"] ?? version)
        }.max { comparator.compareVersion($0.version, toVersion: $1.version) == .orderedAscending }
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Collects each item's elements; the version may also sit on the enclosure.
    private final class Reader: NSObject, XMLParserDelegate {
        var items: [[String: String]] = []
        private var item: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            text = ""
            if name == "item" { item = [:] }
            if name == "enclosure" {
                for key in ["sparkle:version", "sparkle:shortVersionString"] where item?[key] == nil {
                    item?[key] = attributes[key]
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "item" {
                if let item { items.append(item) }
                item = nil
            } else if name.hasPrefix("sparkle:") {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { item?[name] = value }
            }
        }
    }
}
