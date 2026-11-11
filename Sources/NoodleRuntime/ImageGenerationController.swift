import Foundation
import NoodleCore
import Observation
import ProductIdentity

/// The Images tool's models and which bots have it. Models are kept once for every bot;
/// the default is what a bot gets unless it names another.
@MainActor @Observable public final class ImageGenerationController {
    public private(set) var settings = ImageGenerationSettings()
    public private(set) var models: [ImageModel] = []
    public private(set) var failure: String?
    public private(set) var downloadingID: String?
    public private(set) var downloadProgress: AppleModelDownloadProgress?
    public private(set) var cancelling = false
    @ObservationIgnored private var downloadTask: Task<ImageModel, Error>?
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private var readable = true
    /// Receives each bot's grant for the tool broker, now and on every change.
    @ObservationIgnored public var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { publishAssignments() } }
    private func publishAssignments() { onAssignmentsChange?(settings.toolAssignments(readable: readable)) }

    public var store: ImageModelStore { ImageModelStore(repository: repository.rootURL) }
    /// The model a bot gets when it names none: the chosen default, or the first when that was removed.
    public var currentModel: ImageModel? { models.first { $0.id == settings.defaultModel } ?? models.first }
    public var available: [ImageDownloadableModel] { ImageDownloadableModel.available.filter { model in !models.contains { $0.id == model.id } } }

    public init(repository: WorkspaceRepository) {
        self.repository = repository
        do { settings = try ImageGenerationSettings.load(root: repository.rootURL) }
        catch { readable = false; failure = error.localizedDescription }
        models = store.models()
    }

    public func isAssigned(_ agent: AgentRecord) -> Bool { settings.assigned(to: agent.id) }
    public func isAssigned(_ agent: UUID) -> Bool { settings.assigned(to: agent) }

    public func assign(_ enabled: Bool, to agent: AgentRecord) throws { try assign(enabled, to: agent.id) }

    public func assign(_ enabled: Bool, to agent: UUID) throws {
        guard readable else { throw ToolProviderError(failure ?? "Image generation settings could not be read.") }
        var next = settings
        if enabled { next.agents.insert(agent.uuidString) } else { next.agents.remove(agent.uuidString) }
        guard next != settings else { return }
        try next.save(root: repository.rootURL); settings = next
        publishAssignments()
    }

    public func reloadAssignments() throws {
        defer { publishAssignments() }
        do { settings = try ImageGenerationSettings.load(root: repository.rootURL); readable = true }
        catch { readable = false; throw error }
    }

    public func makeDefault(_ model: ImageModel) {
        guard readable else { return }
        var next = settings
        next.defaultModel = model.id
        do { try next.save(root: repository.rootURL); settings = next; failure = nil }
        catch { failure = error.localizedDescription }
    }

    public func download(_ downloadable: ImageDownloadableModel) {
        guard downloadingID == nil else { return }
        downloadingID = downloadable.id
        downloadProgress = nil
        cancelling = false
        failure = nil
        let store = store
        let worker = Task.detached {
            try await store.download(downloadable) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadingID == downloadable.id else { return }
                    self.downloadProgress = progress
                }
            }
        }
        downloadTask = worker
        Task {
            defer { downloadingID = nil; downloadTask = nil; downloadProgress = nil; cancelling = false }
            do {
                _ = try await worker.value
                models = store.models()
                // The first model becomes the default, so the tool works without another step.
                if settings.defaultModel == nil || currentModel?.id != settings.defaultModel, let model = currentModel { makeDefault(model) }
            } catch {
                if !(error is CancellationError) && !worker.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    public func cancelDownload() {
        cancelling = true
        downloadTask?.cancel()
    }

    public func remove(_ model: ImageModel) {
        do {
            try store.remove(id: model.id)
            models = store.models()
            failure = nil
        } catch { failure = error.localizedDescription }
    }
}

/// Runs each generation in the Apple helper, one at a time: a second SDXL model in memory
/// at once would push most Macs into swap.
public actor ImageGenerationHelper {
    private let executable: URL
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    public init(executable: URL) { self.executable = executable }

    public func png(_ request: ImageGenerationRequest) async throws -> Data {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let input = try JSONEncoder().encode(request)
        let executable = executable
        let process = Process()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    throw ToolProviderError("This \(ProductIdentity.current.name) build has no image generation helper.")
                }
                process.executableURL = executable
                process.arguments = ["--generate-image"]
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                // A helper that exits early reports EPIPE, not SIGPIPE.
                BrokenPipe.reportAsError(stdin.fileHandleForWriting.fileDescriptor)
                try process.run()
                try stdin.fileHandleForWriting.write(contentsOf: input)
                try stdin.fileHandleForWriting.close()
                async let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
                let png = stdout.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: await errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                process.waitUntilExit()
                try Task.checkCancellation()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    throw ToolProviderError(message.isEmpty ? "Image generation stopped unexpectedly. The Mac may be short of memory." : message)
                }
                return png
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
