import Foundation

/// A reviewed Stable Diffusion XL checkpoint. Revisions and hashes are pinned so upstream
/// changes cannot silently change what a model downloads. Only fp16 weights are fetched;
/// they are stored under the names the MLX loader reads.
public struct ImageDownloadableModel: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// One line on what the model is good for, its speed and its licence.
    public let summary: String
    public let repository: String
    public let revision: String
    /// What the model was tuned for: denoising steps, guidance and the longer image side.
    public let steps: Int
    public let guidance: Double
    public let size: Int
    let files: [File]

    public var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    public var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }

    struct File: Sendable {
        /// The path in the repository, and the path the loader expects.
        let source: String
        let name: String
        let byteCount: Int64
        let digest: AppleDownloadableModel.Digest
    }

    /// Physical memory, in GiB, SDXL runs comfortably with.
    public static let memory = 16

    public static let available: [Self] = [
        .init(id: "sdxl-turbo", name: "SDXL Turbo",
              summary: "Fastest: an image in a few seconds at 512 pixels. Stability AI’s non-commercial licence.",
              repository: "stabilityai/sdxl-turbo", revision: "71153311d3dbb46851df1931d3ca6e939de83304",
              steps: 2, guidance: 0, size: 512, files: [
                .init(source: "unet/config.json", name: "unet/config.json", byteCount: 1776, digest: .gitSHA1("220d7ae3e59ce3484c7eeb47ef2ac9db5097e29a")),
                .init(source: "unet/diffusion_pytorch_model.fp16.safetensors", name: "unet/diffusion_pytorch_model.safetensors", byteCount: 5135149760, digest: .sha256("48fa46161a745f48d4054df3fe13804ee255486bca893403b60373c188fd1bdb")),
                .init(source: "text_encoder/config.json", name: "text_encoder/config.json", byteCount: 565, digest: .gitSHA1("8e91c97936ad0b2c1356f03de8d47589b5232704")),
                .init(source: "text_encoder/model.fp16.safetensors", name: "text_encoder/model.safetensors", byteCount: 246144152, digest: .sha256("660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd")),
                .init(source: "text_encoder_2/config.json", name: "text_encoder_2/config.json", byteCount: 575, digest: .gitSHA1("f9e084535c55110233f44ccc6c7f9d0e1540f8be")),
                .init(source: "text_encoder_2/model.fp16.safetensors", name: "text_encoder_2/model.safetensors", byteCount: 1389382176, digest: .sha256("ec310df2af79c318e24d20511b601a591ca8cd4f1fce1d8dff822a356bcdb1f4")),
                .init(source: "vae/config.json", name: "vae/config.json", byteCount: 607, digest: .gitSHA1("ae14cf90e29b12134a53383691c98c73dee5d422")),
                .init(source: "vae/diffusion_pytorch_model.fp16.safetensors", name: "vae/diffusion_pytorch_model.safetensors", byteCount: 167335342, digest: .sha256("02ee4bd18e5d16e7fe5fc5b85b4aefa2cba6db28897f674226c9d6ddd2f34f06")),
                .init(source: "scheduler/scheduler_config.json", name: "scheduler/scheduler_config.json", byteCount: 459, digest: .gitSHA1("0359d7abb0b9c7b4a433be2db87cefea03c06ea5")),
                .init(source: "tokenizer/vocab.json", name: "tokenizer/vocab.json", byteCount: 1059962, digest: .gitSHA1("469be27c5c010538f845f518c4f5e8574c78f7c8")),
                .init(source: "tokenizer/merges.txt", name: "tokenizer/merges.txt", byteCount: 524619, digest: .gitSHA1("76e821f1b6f0a9709293c3b6b51ed90980b3166b")),
                .init(source: "tokenizer_2/vocab.json", name: "tokenizer_2/vocab.json", byteCount: 1059962, digest: .gitSHA1("469be27c5c010538f845f518c4f5e8574c78f7c8")),
                .init(source: "tokenizer_2/merges.txt", name: "tokenizer_2/merges.txt", byteCount: 524619, digest: .gitSHA1("76e821f1b6f0a9709293c3b6b51ed90980b3166b")),
              ]),
        .init(id: "dreamshaper-xl-turbo", name: "DreamShaper XL Turbo",
              summary: "Fast, versatile 1024-pixel images, from art to photos, with few content limits. Open RAIL++ licence.",
              repository: "Lykon/dreamshaper-xl-v2-turbo", revision: "f70ad5bce436c640d23fc02cd0a6ccc787280b6e",
              steps: 6, guidance: 2, size: 1024, files: [
                .init(source: "unet/config.json", name: "unet/config.json", byteCount: 1773, digest: .gitSHA1("ae0e13ab9e256164d01be6cadae046b03a3e1a07")),
                .init(source: "unet/diffusion_pytorch_model.fp16.safetensors", name: "unet/diffusion_pytorch_model.safetensors", byteCount: 5135149760, digest: .sha256("c1217e273e6fd7570c2ae9d38172323ff0b6f8ac7f2000b3ba99d4851906ee1e")),
                .init(source: "text_encoder/config.json", name: "text_encoder/config.json", byteCount: 560, digest: .gitSHA1("5e5371d776ace0d73c7d9502d12b050cf32f5988")),
                .init(source: "text_encoder/model.fp16.safetensors", name: "text_encoder/model.safetensors", byteCount: 246144152, digest: .sha256("3dea4e3e892df8d0d41540f7bacfdec4d5c978d1aaf2375f0a56d41d814a640f")),
                .init(source: "text_encoder_2/config.json", name: "text_encoder_2/config.json", byteCount: 570, digest: .gitSHA1("5429d7a70b8b88e8c8e4806afac10427ab88127f")),
                .init(source: "text_encoder_2/model.fp16.safetensors", name: "text_encoder_2/model.safetensors", byteCount: 1389382176, digest: .sha256("30b466dbbac35c5c63d0fc1893c17433f0d367886c1081d4a699ce728ed013af")),
                .init(source: "vae/config.json", name: "vae/config.json", byteCount: 602, digest: .gitSHA1("e9b208cce788aac2a8b78350d8273d8f76157de4")),
                .init(source: "vae/diffusion_pytorch_model.fp16.safetensors", name: "vae/diffusion_pytorch_model.safetensors", byteCount: 167335342, digest: .sha256("5ebe0b826867138fc37d4474983ef0b487cef39d8f3cd84228f3b5c5aba241d4")),
                .init(source: "scheduler/scheduler_config.json", name: "scheduler/scheduler_config.json", byteCount: 558, digest: .gitSHA1("fc79d9b7d87cc4422536aa872b855f2341001d15")),
                .init(source: "tokenizer/vocab.json", name: "tokenizer/vocab.json", byteCount: 1059962, digest: .gitSHA1("469be27c5c010538f845f518c4f5e8574c78f7c8")),
                .init(source: "tokenizer/merges.txt", name: "tokenizer/merges.txt", byteCount: 524619, digest: .gitSHA1("76e821f1b6f0a9709293c3b6b51ed90980b3166b")),
                .init(source: "tokenizer_2/vocab.json", name: "tokenizer_2/vocab.json", byteCount: 1059962, digest: .gitSHA1("469be27c5c010538f845f518c4f5e8574c78f7c8")),
                .init(source: "tokenizer_2/merges.txt", name: "tokenizer_2/merges.txt", byteCount: 524619, digest: .gitSHA1("76e821f1b6f0a9709293c3b6b51ed90980b3166b")),
              ]),
        .init(id: "juggernaut-xl", name: "Juggernaut XL",
              summary: "Detailed photorealistic 1024-pixel images with few content limits. Slowest: about a minute or more. OpenRAIL-M licence.",
              repository: "RunDiffusion/Juggernaut-XL-v9", revision: "cf419233522daa0b9ea36c3aff98fa2cab1fb0fb",
              steps: 30, guidance: 5, size: 1024, files: [
                .init(source: "unet/config.json", name: "unet/config.json", byteCount: 1778, digest: .gitSHA1("cee677f4253b72ed8ac7b6380f087fd08cf733ea")),
                .init(source: "unet/diffusion_pytorch_model.fp16.safetensors", name: "unet/diffusion_pytorch_model.safetensors", byteCount: 5135149760, digest: .sha256("cf1ee18eb36712683f50c1e674634875e2adf7413d7492d5f9aa7e69e1a8c17a")),
                .init(source: "text_encoder/config.json", name: "text_encoder/config.json", byteCount: 565, digest: .gitSHA1("ee080c71f6e52e8c865f0ce11545603ffc96378c")),
                .init(source: "text_encoder/model.fp16.safetensors", name: "text_encoder/model.safetensors", byteCount: 246144152, digest: .sha256("698656aa4f452e1f8f38287240054a9b8d339b3051ec17d77d63bdb5605db01a")),
                .init(source: "text_encoder_2/config.json", name: "text_encoder_2/config.json", byteCount: 575, digest: .gitSHA1("c37f01f079566bc3fcec2f39e4ac5daa444840ab")),
                .init(source: "text_encoder_2/model.fp16.safetensors", name: "text_encoder_2/model.safetensors", byteCount: 1389382176, digest: .sha256("9962c194f50a9c580ebe573f2a4756d76dcd29abe15bffb0a5905509eb6a8dda")),
                .init(source: "vae/config.json", name: "vae/config.json", byteCount: 607, digest: .gitSHA1("5f217e408a879cda4d71ab25f8a27d41b49c7db7")),
                .init(source: "vae/diffusion_pytorch_model.fp16.safetensors", name: "vae/diffusion_pytorch_model.safetensors", byteCount: 167335342, digest: .sha256("6353737672c94b96174cb590f711eac6edf2fcce5b6e91aa9d73c5adc589ee48")),
                .init(source: "scheduler/scheduler_config.json", name: "scheduler/scheduler_config.json", byteCount: 496, digest: .gitSHA1("314728caf3bf70369105692a562b4eb0695cd4ec")),
                .init(source: "tokenizer/vocab.json", name: "tokenizer/vocab.json", byteCount: 1059962, digest: .gitSHA1("469be27c5c010538f845f518c4f5e8574c78f7c8")),
                .init(source: "tokenizer/merges.txt", name: "tokenizer/merges.txt", byteCount: 524619, digest: .gitSHA1("76e821f1b6f0a9709293c3b6b51ed90980b3166b")),
                .init(source: "tokenizer_2/vocab.json", name: "tokenizer_2/vocab.json", byteCount: 1059962, digest: .gitSHA1("469be27c5c010538f845f518c4f5e8574c78f7c8")),
                .init(source: "tokenizer_2/merges.txt", name: "tokenizer_2/merges.txt", byteCount: 524619, digest: .gitSHA1("76e821f1b6f0a9709293c3b6b51ed90980b3166b")),
              ]),
    ]
}

/// A downloaded image model, as the tool and Settings list it.
public struct ImageModel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let repository: String
    public let steps: Int
    public let guidance: Double
    public let size: Int
    public let byteCount: Int64
    public init(id: String, name: String, summary: String, repository: String, steps: Int, guidance: Double, size: Int, byteCount: Int64) {
        self.id = id; self.name = name; self.summary = summary; self.repository = repository
        self.steps = steps; self.guidance = guidance; self.size = size; self.byteCount = byteCount
    }
}

/// What one generation asks of the helper. The helper reads it as JSON on standard input
/// and writes the PNG to standard output.
public struct ImageGenerationRequest: Codable, Equatable, Sendable {
    public var weights: URL
    public var prompt: String
    public var negativePrompt: String
    public var steps: Int
    public var guidance: Double
    public var width: Int
    public var height: Int
    public var seed: UInt64
    /// A PNG to start from, already `width` by `height`. Nil makes the image from the prompt alone.
    public var image: Data?
    /// How much of the starting image to rework, 0–1: low keeps its layout and colours.
    public var strength: Double
    public init(weights: URL, prompt: String, negativePrompt: String, steps: Int, guidance: Double,
                width: Int, height: Int, seed: UInt64, image: Data? = nil, strength: Double = 1) {
        self.weights = weights; self.prompt = prompt; self.negativePrompt = negativePrompt; self.steps = steps
        self.guidance = guidance; self.width = width; self.height = height; self.seed = seed
        self.image = image; self.strength = strength
    }
}

/// Which model is the default and which bots have the tool. One file beside the
/// calendar and browser assignments, so bot settings checkpoints cover it.
public struct ImageGenerationSettings: Codable, Equatable, Sendable {
    public static let file = "image-generation.json"
    /// The resource kind the tool broker enforces; each bot that has the tool is granted `default`.
    public static let kind = "image-generation"
    public var version = 1
    public var defaultModel: String?
    public var agents: Set<String> = []
    public init() {}
    public func assigned(to agent: UUID) -> Bool { agents.contains(agent.uuidString) }
    public static func load(root: URL) throws -> Self {
        let url = root.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: MCPBridgeFiles.read(url, limit: 1_048_576))
        guard value.version == 1 else {
            throw ToolProviderError("Unsupported image generation settings. Existing settings were not changed.")
        }
        return value
    }
    public func save(root: URL) throws { try MCPBridgeFiles.write(self, to: root.appendingPathComponent(Self.file)) }
    /// What the tool broker enforces. Settings that could not be read grant nothing.
    public func toolAssignments(readable: Bool) -> [UUID: Set<String>] {
        guard readable else { return [:] }
        return Dictionary(uniqueKeysWithValues: agents.compactMap { UUID(uuidString: $0).map { ($0, ["default"]) } })
    }
}

/// What the Images tool reads on every call: the downloaded models, the default's ID and
/// where a model's weights are.
public struct ImageLibrary: Sendable {
    public var models: [ImageModel]
    public var defaultModel: String?
    public var weights: @Sendable (String) throws -> URL
    public init(models: [ImageModel], defaultModel: String?, weights: @escaping @Sendable (String) throws -> URL) {
        self.models = models; self.defaultModel = defaultModel; self.weights = weights
    }
    /// The chosen default, or the first model when it was removed.
    public var current: ImageModel? { models.first { $0.id == defaultModel } ?? models.first }

    /// From disk, so a call needs nothing from the main actor.
    public static func load(root: URL) -> Self {
        let store = ImageModelStore(repository: root)
        return .init(models: store.models(), defaultModel: (try? ImageGenerationSettings.load(root: root))?.defaultModel,
                     weights: { try store.weights(id: $0) })
    }
}

/// Downloaded image models, one folder each under `ImageModels`. Weights are data owned by
/// the app; only the helper that generates reads them.
public struct ImageModelStore: Sendable {
    public let directory: URL
    private static let metadata = "model.json"
    private static let staging = ".download-"
    public init(repository: URL) { directory = repository.appendingPathComponent("ImageModels", isDirectory: true) }

    public func models() -> [ImageModel] {
        let catalogue = ImageDownloadableModel.available.map(\.id)
        return catalogue.compactMap { try? model(id: $0) }
    }

    public func model(id: String) throws -> ImageModel {
        let url = try folder(id: id).appendingPathComponent(Self.metadata)
        let model = try JSONDecoder().decode(ImageModel.self, from: MCPBridgeFiles.read(url, limit: 65_536))
        guard model.id == id else { throw ToolProviderError("The image model information is invalid. Download the model again.") }
        return model
    }

    /// The MLX loader resolves files as a Hugging Face cache laid out for SDXL Turbo, whatever
    /// SDXL checkpoint it is, so every model's weights sit under that one path.
    public func weights(id: String) throws -> URL { try folder(id: id).appendingPathComponent("weights", isDirectory: true) }
    public static let loaderPath = "models/stabilityai/sdxl-turbo"

    public func remove(id: String) throws { try FileManager.default.removeItem(at: folder(id: id)) }

    private func folder(id: String) throws -> URL {
        guard ImageDownloadableModel.available.contains(where: { $0.id == id }) else {
            throw ToolProviderError("There is no image model named \(id).")
        }
        return directory.appendingPathComponent(id, isDirectory: true)
    }

    /// Partial weights left by a crash or force quit. Call before any download starts.
    public func removeAbandonedStaging() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(Self.staging) { try? FileManager.default.removeItem(at: entry) }
    }

    public func download(_ downloadable: ImageDownloadableModel,
                         progress: @escaping @Sendable (AppleModelDownloadProgress) -> Void = { _ in }) async throws -> ImageModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let available = try availableCapacity(at: directory)
        if (try? model(id: downloadable.id)) == nil, let available,
           available < downloadable.byteCount + 1_073_741_824 {
            throw ToolProviderError("Not enough disk space: this model needs \(ByteCountFormatter.string(fromByteCount: downloadable.byteCount + 1_073_741_824, countStyle: .file)) free.")
        }
        return try await download(downloadable, progress: progress) { url, destination, byteCount, received in
            try await AppleModelDownloader.fetchResource(url, destination: destination, byteCount: byteCount, progress: received)
        }
    }

    func download(_ downloadable: ImageDownloadableModel, progress: @escaping @Sendable (AppleModelDownloadProgress) -> Void,
                  fetch: AppleModelDownloader.Fetch) async throws -> ImageModel {
        if let existing = try? model(id: downloadable.id) { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(Self.staging + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let weights = staging.appendingPathComponent("weights", isDirectory: true).appendingPathComponent(Self.loaderPath, isDirectory: true)
        var completed: Int64 = 0
        for file in downloadable.files {
            try Task.checkCancellation()
            let destination = weights.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = downloadable.sourceURL.appendingPathComponent("resolve").appendingPathComponent(downloadable.revision)
                .appendingPathComponent(file.source)
            let previous = completed
            progress(.init(phase: .downloading, completedBytes: previous, totalBytes: downloadable.byteCount))
            try await fetch(url, destination, file.byteCount) { received in
                progress(.init(phase: .downloading, completedBytes: previous + min(file.byteCount, max(0, received)),
                               totalBytes: downloadable.byteCount))
            }
            progress(.init(phase: .verifying, completedBytes: previous + file.byteCount, totalBytes: downloadable.byteCount))
            try AppleModelDownloader.verify(destination, file: .init(name: file.name, byteCount: file.byteCount, digest: file.digest))
            completed += file.byteCount
        }
        try Task.checkCancellation()
        let model = ImageModel(id: downloadable.id, name: downloadable.name, summary: downloadable.summary,
                               repository: downloadable.repository, steps: downloadable.steps, guidance: downloadable.guidance,
                               size: downloadable.size, byteCount: downloadable.byteCount)
        try JSONEncoder().encode(model).write(to: staging.appendingPathComponent(Self.metadata), options: .atomic)
        // Another settings window may have finished the same download.
        if let existing = try? self.model(id: downloadable.id) { return existing }
        try FileManager.default.moveItem(at: staging, to: folder(id: downloadable.id))
        return model
    }
}
