import ComputerCore
import Foundation

public struct ComputerResourceCapabilities: Equatable, Sendable {
    public let resourceEditing: Bool
    public let diskGrowth: Bool
}

protocol ComputerKindBehavior {
    var capabilities: ComputerResourceCapabilities { get }
    func growDisk(in directory: URL, to gibibytes: Int) throws
}

private struct FixedDiskBehavior: ComputerKindBehavior {
    let capabilities: ComputerResourceCapabilities

    init(resourceEditing: Bool) {
        capabilities = ComputerResourceCapabilities(resourceEditing: resourceEditing, diskGrowth: false)
    }

    func growDisk(in directory: URL, to gibibytes: Int) throws {
        throw ComputerError("This computer’s disk capacity cannot change.")
    }
}

extension ComputerKind {
    var behavior: any ComputerKindBehavior {
        switch self {
        case .macOS, .linux, .container: FixedDiskBehavior(resourceEditing: true)
        case .localMac, .ssh: FixedDiskBehavior(resourceEditing: false)
        case .windows: WindowsKindBehavior()
        }
    }

    public var capabilities: ComputerResourceCapabilities { behavior.capabilities }
}
