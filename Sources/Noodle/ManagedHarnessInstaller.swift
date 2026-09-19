import Foundation
import NoodleCore
import OSLog

/// The sandboxed app downloads and unpacks. It cannot make the result runnable:
/// the Agent Host checks the vendor's signature and moves it into place.
@MainActor final class ManagedHarnessInstaller: HarnessInstalling {
    private let store: ManagedHarnessStore
    private let log = Logger(subsystem: "com.pdparchitect.noodle", category: "HarnessInstall")
    init(store: ManagedHarnessStore) { self.store = store }

    func manages(_ installation: HarnessInstallation) -> Bool { store.manages(installation) }

    func install(_ provider: HarnessProvider, progress: @escaping @MainActor (HarnessDownloadProgress) -> Void) async throws {
        let store = store, log = log
        log.notice("install \(provider.rawValue, privacy: .public): staging into \(store.directory.path, privacy: .public)")
        let staged: StagedHarness?
        do {
            staged = try await Task.detached(priority: .utility) {
                try await HarnessDownloader().stage(provider, into: store) { update in Task { @MainActor in progress(update) } }
            }.value
        } catch {
            log.error("install \(provider.rawValue, privacy: .public): staging failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let staged else {
            log.notice("install \(provider.rawValue, privacy: .public): current release already installed")
            return
        }
        progress(.init(phase: .installing, completedBytes: 0, totalBytes: 0))
        do {
            let published = try await HarnessPublishOperation().run(staged)
            let found = store.executable(provider)?.path ?? "nothing"
            log.notice("install \(provider.rawValue, privacy: .public): published \(published, privacy: .public); discovery sees \(found, privacy: .public)")
        } catch {
            log.error("install \(provider.rawValue, privacy: .public): publish failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: store.staging(staged.staging))
            throw error
        }
    }

    func remove(_ provider: HarnessProvider) throws { try store.remove(provider) }
    func versions(_ provider: HarnessProvider) -> [String] { store.versions(provider).map(\.text) }
    func remove(_ provider: HarnessProvider, version: String) throws { try store.remove(provider, version: version) }
}

@MainActor private final class HarnessPublishOperation {
    private let connection: ExtendedAgentConnection
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    init() throws { connection = try ExtendedAgentConnection() }

    /// The published executable's path, as the Agent Host reports it.
    func run(_ staged: StagedHarness) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            connection.onFailure = { [weak self] error in
                Task { @MainActor in self?.finish(.failure(HarnessSetupError(error))) }
            }
            connection.publishHarness(staged) { [weak self] path, error in
                Task { @MainActor in
                    self?.finish(path.map { .success($0) } ?? .failure(HarnessSetupError(error ?? "The harness could not be installed.")))
                }
            }
            // Signature checks read every page of a large executable.
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(HarnessSetupError("Installing the harness timed out.")))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
