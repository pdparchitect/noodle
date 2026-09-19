import CryptoKit
import Darwin
import Foundation

/// Harnesses Noodle installs for a user who has none of their own. Each version
/// lives in `Harnesses/<harness>/<version>/` inside Noodle's storage. The
/// sandboxed app can only stage a download; the Agent Host verifies the vendor's
/// signature and publishes it, and checks it again before every launch.
public struct ManagedHarnessStore: Sendable {
    public static let directoryName = "Harnesses"
    static let stagingName = ".staging"
    public let directory: URL

    /// `root` is Noodle's storage root, beside Agents and Conversations.
    public init(root: URL) {
        directory = AgentStorageLayout.canonicalURL(root).appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// Installed versions with their main executable, oldest first.
    public func versions(_ provider: HarnessProvider) -> [HarnessVersion] {
        guard let distribution = HarnessDistribution(provider),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder(provider).path) else { return [] }
        return names.compactMap(HarnessVersion.init).filter {
            Self.isProgram(folder(provider, version: $0).appendingPathComponent(distribution.executablePath))
        }.sorted()
    }

    /// The App Sandbox refuses execute access to everything in the app's own
    /// container, so asking whether the file is executable always answers no
    /// there. Only the Agent Host ever runs it, after checking its signature.
    private static func isProgram(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber else { return false }
        return mode.intValue & 0o111 != 0
    }

    /// The newest installed version's main executable.
    public func executable(_ provider: HarnessProvider) -> URL? {
        guard let distribution = HarnessDistribution(provider), let version = versions(provider).last else { return nil }
        return folder(provider, version: version).appendingPathComponent(distribution.executablePath)
    }

    public func manages(_ installation: HarnessInstallation) -> Bool {
        installation.executablePath.map(contains) ?? false
    }

    /// By spelling or by destination: a link into or out of this folder is still held to its rules.
    func contains(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return [url.standardizedFileURL, AgentStorageLayout.canonicalURL(url)].contains { $0.path.hasPrefix(directory.path + "/") }
    }

    /// Undoes an update that turned out not to work with Noodle.
    public func remove(_ provider: HarnessProvider, version: String) throws {
        guard let version = HarnessVersion(version), AgentStorageLayout.exists(folder(provider, version: version)) else { return }
        try FileManager.default.removeItem(at: folder(provider, version: version))
    }

    public func remove(_ provider: HarnessProvider) throws {
        guard AgentStorageLayout.exists(folder(provider)) else { return }
        try FileManager.default.removeItem(at: folder(provider))
    }

    public func staging(_ id: UUID) -> URL {
        directory.appendingPathComponent(Self.stagingName, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Interrupted downloads are never resumed.
    public func removeAbandonedStaging() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.stagingName, isDirectory: true))
    }

    func folder(_ provider: HarnessProvider) -> URL {
        directory.appendingPathComponent(provider.rawValue, isDirectory: true)
    }

    func folder(_ provider: HarnessProvider, version: HarnessVersion) -> URL {
        folder(provider).appendingPathComponent(version.text, isDirectory: true)
    }

    // MARK: Agent Host

    /// Nil for a path outside this store, so the caller falls back to the
    /// vendor's own installation rules.
    public func trustedExecutable(at path: String, provider: HarnessProvider) throws -> URL? {
        guard contains(path) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let distribution = HarnessDistribution(provider),
              let version = versions(provider).first(where: {
                  folder(provider, version: $0).appendingPathComponent(distribution.executablePath).path == url.path
              }) else {
            throw HarnessSetupError("This \(provider.displayName) installation is not one Noodle installed.")
        }
        let package = folder(provider, version: version)
        for folder in [directory, folder(provider), package] { try AgentStorageLayout.requireDirectory(folder) }
        try verify(provider, package: package, distribution: distribution)
        return url
    }

    /// Moves a staged download into place after checking the vendor's signature.
    /// Only identifiers arrive from the app; every path is derived here.
    public func publish(_ provider: HarnessProvider, version text: String, staging id: UUID,
                        running: () -> [String] = ManagedHarnessStore.runningExecutables) throws -> URL {
        guard let distribution = HarnessDistribution(provider), let version = HarnessVersion(text) else {
            throw HarnessSetupError("Noodle cannot install this harness version.")
        }
        let staged = staging(id)
        for folder in [directory, staged.deletingLastPathComponent(), staged] { try AgentStorageLayout.requireDirectory(folder) }
        defer { try? FileManager.default.removeItem(at: staged) }
        try release(staged)
        try verify(provider, package: staged, distribution: distribution)

        let destination = folder(provider, version: version)
        try FileManager.default.createDirectory(at: folder(provider), withIntermediateDirectories: true)
        try AgentStorageLayout.requireDirectory(folder(provider))
        if AgentStorageLayout.exists(destination) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staged, to: destination)
        prune(provider, running: running())
        return destination.appendingPathComponent(distribution.executablePath)
    }

    /// Keeps the previous version, and any older one a bot is still running from:
    /// bots run for days, and the tools beside the executable are started on demand.
    func prune(_ provider: HarnessProvider, running: [String]) {
        for old in versions(provider).dropLast(2) {
            let prefix = folder(provider, version: old).path + "/"
            if !running.contains(where: { $0.hasPrefix(prefix) }) { try? FileManager.default.removeItem(at: folder(provider, version: old)) }
        }
    }

    /// Executable paths of this user's running processes, as the unsandboxed Agent Host sees them.
    public static func runningExecutables() -> [String] {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(0, count)).compactMap { pid in
            proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        }
    }

    private func verify(_ provider: HarnessProvider, package: URL, distribution: HarnessDistribution) throws {
        let executable = package.appendingPathComponent(distribution.executablePath)
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              executable.resolvingSymlinksInPath().path == executable.standardizedFileURL.path else {
            throw HarnessSetupError("The \(provider.displayName) executable is missing or redirected.")
        }
        try distribution.verify(package, executable)
    }

    /// Files written by the sandboxed app are quarantined and cannot be executed.
    /// Every entry must stay inside the package before the quarantine is lifted.
    private func release(_ package: URL) throws {
        let root = package.resolvingSymlinksInPath().path
        guard let entries = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
                                                           options: [], errorHandler: nil) else {
            throw HarnessSetupError("The downloaded harness could not be read.")
        }
        for case let entry as URL in entries {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                guard (entry.resolvingSymlinksInPath().path + "/").hasPrefix(root + "/") else {
                    throw HarnessSetupError("The downloaded harness links outside its own folder.")
                }
            } else if values.isRegularFile != true, values.isDirectory != true {
                throw HarnessSetupError("The downloaded harness contains an unsupported file.")
            }
            guard removexattr(entry.path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
                throw HarnessSetupError("Could not release \(entry.lastPathComponent) from quarantine.")
            }
        }
    }
}

extension HarnessProvider {
    /// Noodle downloads these from the vendor. Only the Agent Host can run them:
    /// the sandboxed app cannot execute anything in its own container.
    public var supportsManagedInstallation: Bool { HarnessDistribution(self) != nil }
}

/// How one vendor publishes its macOS release, as that vendor's own installer
/// reads it. Each harness defines its own beside its trust rules; everything
/// else here, in the Agent Host, and in Settings is the same for all of them.
public struct HarnessDistribution: Sendable {
    public struct Release: Equatable, Sendable {
        /// Normalized, and the name of the version folder.
        public let version: String
        let artifact: URL
        let checksums: URL?
    }

    public struct Expectation: Equatable, Sendable {
        enum Algorithm: Sendable { case sha256, sha512 }
        let algorithm: Algorithm
        /// Lowercase hexadecimal.
        let digest: String
        let byteCount: Int64?
    }

    public let provider: HarnessProvider
    /// Main executable, relative to the version folder.
    public let executablePath: String
    let isArchive: Bool
    /// The vendor's pointer to its current release.
    let latest: URL
    /// Downloads follow redirects on the same host only, so this is the full list.
    let hosts: Set<String>
    let version: @Sendable (Data) -> String?
    /// Artifact and optional checksum file for a version, as absolute addresses.
    let addresses: @Sendable (String) -> (artifact: String, checksums: String?)
    let expectation: @Sendable (Release, Data) -> Expectation?
    /// The vendor's pinned signature, for the executable and anything it launches from its package.
    let verify: @Sendable (_ package: URL, _ executable: URL) throws -> Void

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    func release(from data: Data) -> Release? {
        guard let text = version(data), let version = HarnessVersion(text)?.text else { return nil }
        let addresses = addresses(version)
        guard let artifact = URL(string: addresses.artifact) else { return nil }
        return Release(version: version, artifact: artifact, checksums: addresses.checksums.flatMap(URL.init(string:)))
    }

    /// A `shasum`-style listing: one "digest  name" per line.
    static func listedDigest(of name: String, in data: Data) -> String? {
        let lines: [[Substring]] = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true) }
        return lines.first { $0.count == 2 && $0[1] == name }.map { String($0[0]) }
    }

    static func expectation(sha256 digest: String?, byteCount: Int64? = nil) -> Expectation? {
        guard let digest = digest?.lowercased(),
              digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { return nil }
        return Expectation(algorithm: .sha256, digest: digest, byteCount: byteCount)
    }

    /// An npm `dist.integrity` value: "sha512-" and the digest in Base64.
    static func expectation(integrity: String?) -> Expectation? {
        guard let integrity, integrity.hasPrefix("sha512-"),
              let data = Data(base64Encoded: String(integrity.dropFirst(7))), data.count == 64 else { return nil }
        return Expectation(algorithm: .sha512, digest: data.map { String(format: "%02x", $0) }.joined(), byteCount: nil)
    }
}

extension HarnessDistribution {
    /// The registry. A harness absent here is installed from Terminal.
    public init?(_ provider: HarnessProvider) {
        switch provider {
        case .claudeCode: self = .claudeCode
        case .codex: self = .codex
        case .fx: self = .fx
        case .grokBuild: self = .grokBuild
        case .muse: self = .muse
        case .openCode: self = .openCode
        case .apple: return nil
        }
    }
}

public struct HarnessDownloadProgress: Equatable, Sendable {
    public enum Phase: Sendable { case downloading, verifying, unpacking, installing }
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(phase: Phase, completedBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
    public var fraction: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
}

public struct StagedHarness: Equatable, Sendable {
    public let provider: HarnessProvider
    public let version: String
    public let staging: UUID
}

/// Runs in the sandboxed app: network and unpacking stay inside its sandbox, and
/// nothing it produces can run until the Agent Host publishes it.
public struct HarnessDownloader: Sendable {
    typealias FetchData = @Sendable (URL, HarnessDistribution) async throws -> Data
    typealias FetchFile = @Sendable (URL, URL, HarnessDistribution, Int64?, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void
    static let maximumBytes: Int64 = 1_024 * 1_024 * 1_024
    private let fetchData: FetchData
    private let fetchFile: FetchFile
    private let availableCapacity: @Sendable (URL) -> Int64?

    public init() {
        fetchData = { try await Self.data($0, distribution: $1) }
        fetchFile = { try await Self.file($0, destination: $1, distribution: $2, byteCount: $3, progress: $4) }
        availableCapacity = { try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }
    }
    init(fetchData: @escaping FetchData, fetchFile: @escaping FetchFile,
         availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in nil }) {
        self.fetchData = fetchData
        self.fetchFile = fetchFile
        self.availableCapacity = availableCapacity
    }

    /// Nil when the vendor's current release is already installed.
    public func stage(_ provider: HarnessProvider, into store: ManagedHarnessStore,
                      progress: @escaping @Sendable (HarnessDownloadProgress) -> Void = { _ in }) async throws -> StagedHarness? {
        guard let distribution = HarnessDistribution(provider) else {
            throw HarnessSetupError("Noodle cannot install \(provider.displayName). Install it from Terminal.")
        }
        try Task.checkCancellation()
        guard let release = distribution.release(from: try await fetchData(distribution.latest, distribution)) else {
            throw HarnessSetupError("\(provider.displayName) returned an unrecognized release version.")
        }
        if store.versions(provider).contains(where: { $0.text == release.version }) { return nil }
        var expectation: HarnessDistribution.Expectation?
        if let checksums = release.checksums {
            expectation = distribution.expectation(release, try await fetchData(checksums, distribution))
            guard expectation != nil else {
                throw HarnessSetupError("\(provider.displayName) did not publish a checksum for this Mac.")
            }
        }

        store.removeAbandonedStaging()
        let id = UUID(), staged = store.staging(id)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: staged) } }
        // The sandbox may withhold the figure; the download's own size cap still applies.
        if let available = availableCapacity(staged), available < 2 * (expectation?.byteCount ?? Self.maximumBytes) {
            throw HarnessSetupError("Not enough disk space to install \(provider.displayName).")
        }

        let download = staged.deletingLastPathComponent().appendingPathComponent("\(id.uuidString.lowercased()).download")
        defer { try? FileManager.default.removeItem(at: download) }
        try await fetchFile(release.artifact, download, distribution, expectation?.byteCount) { completed, total in
            progress(.init(phase: .downloading, completedBytes: completed, totalBytes: total))
        }
        if let expectation {
            progress(.init(phase: .verifying, completedBytes: 0, totalBytes: 0))
            guard try Self.digest(download, expectation.algorithm) == expectation.digest else {
                throw HarnessSetupError("The \(provider.displayName) download failed verification. Try again.")
            }
        }
        try Task.checkCancellation()
        if distribution.isArchive {
            progress(.init(phase: .unpacking, completedBytes: 0, totalBytes: 0))
            try Self.unpack(download, into: staged)
        } else {
            try FileManager.default.moveItem(at: download, to: staged.appendingPathComponent(distribution.executablePath))
        }
        let executable = staged.appendingPathComponent(distribution.executablePath)
        guard (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw HarnessSetupError("The \(provider.displayName) download did not contain its executable.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Task.checkCancellation()
        finished = true
        return StagedHarness(provider: provider, version: release.version, staging: id)
    }

    static func digest(_ url: URL, _ algorithm: HarnessDistribution.Expectation.Algorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func hash<H: HashFunction>(_ initial: H) throws -> String {
            var hash = initial
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch algorithm {
        case .sha256: return try hash(SHA256())
        case .sha512: return try hash(SHA512())
        }
    }

    /// bsdtar refuses absolute paths, `..`, and writes through symlinks unless
    /// asked otherwise. The Agent Host still checks every entry before publishing.
    static func unpack(_ archive: URL, into folder: URL) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", folder.path, "--no-same-owner"]
        tar.standardInput = FileHandle.nullDevice
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        tar.terminationHandler = { _ in finished.signal() }
        try tar.run()
        if finished.wait(timeout: .now() + 120) == .timedOut {
            tar.terminate()
            throw HarnessSetupError("Unpacking the harness download timed out.")
        }
        guard tar.terminationStatus == 0 else { throw HarnessSetupError("The harness download could not be unpacked.") }
    }

    static func data(_ url: URL, distribution: HarnessDistribution) async throws -> Data {
        guard distribution.allows(url) else { throw HarnessSetupError("Invalid harness download URL.") }
        let session = URLSession(configuration: configuration(resourceTimeout: 20),
                                 delegate: HarnessDownloadDelegate(distribution: distribution), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Noodle-Harness-Install", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1_024 * 1_024 else {
            throw HarnessSetupError("\(distribution.provider.displayName)’s release service is unavailable. Try again later.")
        }
        return data
    }

    static func file(_ url: URL, destination: URL, distribution: HarnessDistribution, byteCount: Int64?,
                     progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard distribution.allows(url) else { throw HarnessSetupError("Invalid harness download URL.") }
        let (completion, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let delegate = HarnessDownloadDelegate(distribution: distribution, destination: destination,
                                               byteCount: byteCount, progress: progress, completion: continuation)
        let session = URLSession(configuration: configuration(resourceTimeout: 60 * 60), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Noodle-Harness-Install", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            task.resume()
            for try await _ in completion {}
            try Task.checkCancellation()
        } onCancel: { task.cancel() }
    }

    private static func configuration(resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}

final class HarnessDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let distribution: HarnessDistribution
    private let destination: URL?
    private let limit: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let completion: AsyncThrowingStream<Void, Error>.Continuation?

    init(distribution: HarnessDistribution, destination: URL? = nil, byteCount: Int64? = nil,
         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
         completion: AsyncThrowingStream<Void, Error>.Continuation? = nil) {
        self.distribution = distribution
        self.destination = destination
        limit = byteCount ?? HarnessDownloader.maximumBytes
        self.progress = progress
        self.completion = completion
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let sameHost = request.url?.host == task.originalRequest?.url?.host
        completionHandler(sameHost && request.url.map(distribution.allows) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            completion?.finish(throwing: HarnessSetupError("The harness download exceeded its expected size."))
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let destination, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw HarnessSetupError("The \(distribution.provider.displayName) download failed. Try again later.")
            }
            // URLSession owns this file only for the duration of the callback.
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { completion?.finish(throwing: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion?.finish(throwing: error) }
        else { completion?.finish() }
    }
}
