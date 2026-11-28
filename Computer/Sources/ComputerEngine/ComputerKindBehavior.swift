import ComputerCore
import Foundation

public struct ComputerCapabilities: Equatable, Sendable {
    public let resourceEditing: Bool
    public let diskGrowth: Bool
}

protocol ComputerKindBehavior {
    var capabilities: ComputerCapabilities { get }
    func growDisk(in directory: URL, to gibibytes: Int) throws
}

private struct FixedDiskBehavior: ComputerKindBehavior {
    let capabilities: ComputerCapabilities

    init(resourceEditing: Bool) {
        capabilities = ComputerCapabilities(resourceEditing: resourceEditing, diskGrowth: false)
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

    public var capabilities: ComputerCapabilities { behavior.capabilities }
}
