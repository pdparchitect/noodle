import Foundation

/// The atomic pointer to a complete base/overlay pair. Prepared updates do not
/// become active until they have booted successfully and this record is replaced.
public struct ContainerDiskState: Codable, Equatable, Sendable {
    public let generation: UUID
    public let previousGeneration: UUID?
    public let imageReference: String
    public let imageDigest: String

    public init(generation: UUID = UUID(), previousGeneration: UUID? = nil,
                imageReference: String, imageDigest: String) {
        self.generation = generation
        self.previousGeneration = previousGeneration
        self.imageReference = imageReference
        self.imageDigest = imageDigest
    }

    public func directory(in computerDirectory: URL) -> URL {
        computerDirectory.appendingPathComponent("Layers").appendingPathComponent(generation.uuidString.lowercased())
    }

    public static func load(in directory: URL) throws -> Self {
        let path = directory.appendingPathComponent("ContainerDisk.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ComputerError("This computer has no overlay disk. Create a new computer to use image updates.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }

    public func activate(in directory: URL) throws {
        let layers = self.directory(in: directory)
        for name in ["Base.ext4", "Upper.ext4", "Mount.ext4", "ImageConfig.json"] {
            guard FileManager.default.fileExists(atPath: layers.appendingPathComponent(name).path) else {
                throw ComputerError("The prepared computer image is incomplete: \(name).")
            }
        }
        let data = try JSONEncoder().encode(self)
        try data.write(to: layers.appendingPathComponent("State.json"), options: .atomic)
        try data.write(to: directory.appendingPathComponent("ContainerDisk.json"), options: .atomic)
    }
}
