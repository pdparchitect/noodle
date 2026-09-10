import Foundation

/// Data-driven presets. Type selects an existing runtime; IDs identify registry entries.
public struct ComputerTemplate: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case desktop, shell
    }

    public let id: String
    public let name: String
    public let type: Kind
    public let description: String
    public let symbol: String
    public let defaultName: String
    public let imageReference: String
    public let defaultCPUs: Int
    public let defaultMemoryGiB: Int
    public let defaultDiskGiB: Int
    public let minimumMemoryGiB: Int
    public let minimumDiskGiB: Int
    public let requiresNetworking: Bool

    // Compatibility accessors also read the catalogue; they do not enumerate presets.
    public var title: String { name }
    public static var allCases: [Self] { ContainerRegistry.bundled.templates }
    public static var desktop: Self { ContainerRegistry.bundled.templates.first { $0.type == .desktop }! }
    public static var shell: Self { ContainerRegistry.bundled.templates.first { $0.type == .shell }! }

    public func makeComputer(name: String? = nil) -> Computer {
        Computer(name: name ?? defaultName, kind: .container, cpuCount: defaultCPUs,
                 memoryGiB: defaultMemoryGiB, diskGiB: defaultDiskGiB,
                 imageReference: imageReference)
    }
}
