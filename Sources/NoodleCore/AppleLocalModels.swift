import Foundation

/// Imported weights are data owned by the app. Bots receive read access only.
public struct AppleLocalModel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let contextSize: Int
    public let byteCount: Int64
    public let modelType: String
    public let sourceRepository: String?

    public var harnessModel: HarnessModel {
        .init(id: id, displayName: name + " (MLX)",
              description: "Local text model · \(min(contextSize, 32_768).formatted()) token context · \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)). Loads when used.",
              supportedEfforts: [], defaultEffort: "", isDefault: false)
    }
}

public struct AppleLocalModelStore: Sendable {
    public let directory: URL
    private static let metadata = ".noodle-model.json"
    public init(repository: URL) { directory = repository.appendingPathComponent("AppleModels", isDirectory: true) }
    public init(directory: URL) { self.directory = directory }

    public func models() throws -> [AppleLocalModel] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { folder -> AppleLocalModel? in
                guard Self.validIdentifier(folder.lastPathComponent),
                      let model = try? model(id: folder.lastPathComponent) else { return nil }
                return model
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func validIdentifier(_ id: String) -> Bool {
        id.hasPrefix("mlx-") && UUID(uuidString: String(id.dropFirst(4))) != nil
            && id == id.lowercased()
    }

    public func folder(id: String) throws -> URL {
        guard Self.validIdentifier(id) else { throw HarnessSetupError("Invalid local model identifier.") }
        let folder = directory.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard folder.resolvingSymlinksInPath().path == folder.path else {
            throw HarnessSetupError("Local models must not contain symbolic links.")
        }
        return folder
    }

    public func model(id: String) throws -> AppleLocalModel {
        let folder = try folder(id: id)
        let metadata = folder.appendingPathComponent(Self.metadata)
        try Self.regularFile(metadata, maximumSize: 65_536)
        let model = try JSONDecoder().decode(AppleLocalModel.self, from: Data(contentsOf: metadata))
        guard model.id == id, (1_024...1_048_576).contains(model.contextSize),
              !model.name.isEmpty, model.name.count <= 120 else {
            throw HarnessSetupError("The imported model information is invalid. Import the model again.")
        }
        return model
    }

    /// Copy only model resources, never executable code or linked files. Publish
    /// the catalogue entry only after the complete copy has been validated.
    public func importModel(from source: URL, sourceRepository: String? = nil) throws -> AppleLocalModel {
        let source = source.standardizedFileURL
        guard source.resolvingSymlinksInPath().path == source.path else {
            throw HarnessSetupError("Choose a model folder containing regular files, not symbolic links.")
        }
        let configURL = source.appendingPathComponent("config.json")
        try Self.regularFile(configURL, maximumSize: 4_194_304)
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
              let modelType = config["model_type"] as? String,
              // These text families have tool-aware templates supported by MLX.
              ["qwen2", "qwen3", "qwen3_moe", "llama"].contains(modelType),
              let context = config["max_position_embeddings"] as? Int,
              (1_024...1_048_576).contains(context), config["vision_config"] == nil else {
            throw HarnessSetupError("Import an MLX Qwen2, Qwen3, or Llama text chat model with a valid context size.")
        }
        let files = try Self.resources(in: source)
        let names = Set(files.map(\.lastPathComponent))
        guard names.contains("tokenizer.json"), names.contains("tokenizer_config.json"),
              names.contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw HarnessSetupError("The model folder needs tokenizer.json, tokenizer_config.json, and its .safetensors weights.")
        }
        let indexURL = source.appendingPathComponent("model.safetensors.index.json")
        if names.contains(indexURL.lastPathComponent) {
            try Self.regularFile(indexURL, maximumSize: 4_194_304)
            guard let index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any],
                  let weights = index["weight_map"] as? [String: String], !weights.isEmpty,
                  weights.values.allSatisfy({ names.contains($0) && $0.hasSuffix(".safetensors") }) else {
                throw HarnessSetupError("The model's weight index references missing or invalid shards. Download the complete model folder.")
            }
        }
        let tokenizerConfig = source.appendingPathComponent("tokenizer_config.json")
        try Self.regularFile(tokenizerConfig, maximumSize: 4_194_304)
        guard let tokenizer = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenizerConfig)) as? [String: Any],
              tokenizer["chat_template"] != nil || names.contains("chat_template.jinja") else {
            throw HarnessSetupError("This model has no chat template. Import a chat/instruct model.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "mlx-" + UUID().uuidString.lowercased()
        let staging = directory.appendingPathComponent(".import-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var size: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: destination)
            try Self.regularFile(destination)
            size += (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        let model = AppleLocalModel(id: id, name: String(source.lastPathComponent.prefix(120)),
                                   contextSize: context, byteCount: size, modelType: modelType,
                                   sourceRepository: sourceRepository)
        try Task.checkCancellation()
        try JSONEncoder().encode(model).write(to: staging.appendingPathComponent(Self.metadata), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: folder(id: id))
        return model
    }

    public func remove(id: String) throws {
        _ = try model(id: id)
        try FileManager.default.removeItem(at: folder(id: id))
    }

    public func validateResources(id: String) throws {
        _ = try model(id: id)
        _ = try Self.resources(in: folder(id: id))
    }

    private static func resources(in folder: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && ["json", "safetensors", "model", "txt", "jinja"].contains($0.pathExtension) }
        guard files.count <= 256 else { throw HarnessSetupError("This model contains too many resource files.") }
        for file in files { try regularFile(file) }
        return files
    }

    private static func regularFile(_ file: URL, maximumSize: Int64 = 68_719_476_736) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0, size.int64Value <= maximumSize else {
            throw HarnessSetupError("Invalid model resource: \(file.lastPathComponent). Use regular, nonempty files.")
        }
    }
}
