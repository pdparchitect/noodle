import Foundation

/// Launch-facing presets, separate from the runtime kinds stored on disk.
/// VM runtimes remain supported without appearing in the v1 creation flow.
public enum ComputerTemplate: String, CaseIterable, Sendable {
    case desktop, shell

    public var title: String { self == .desktop ? "Desktop" : "Shell" }
    public var symbol: String { self == .desktop ? "desktopcomputer" : "terminal" }
    public var defaultName: String { "My \(title)" }
    public var detail: String {
        switch self {
        case .desktop: "A Linux desktop with a browser, terminal and file manager, powered by Launcher. Downloads about 540 MB."
        case .shell: "A lightweight Alpine Linux computer with an interactive terminal. Install packages and keep your files between sessions."
        }
    }
    public var imageReference: String {
        self == .desktop ? Computer.desktopImage : Computer.shellImage
    }
    public var defaultCPUs: Int { self == .desktop ? 4 : 2 }
    public var defaultMemoryGiB: Int { self == .desktop ? 4 : 1 }
    public var defaultDiskGiB: Int { self == .desktop ? 32 : 4 }
    public var minimumMemoryGiB: Int { self == .desktop ? 2 : 1 }
    public var minimumDiskGiB: Int { self == .desktop ? 8 : 4 }
    public var requiresNetworking: Bool { self == .desktop }

    public func makeComputer(name: String? = nil) -> Computer {
        Computer(name: name ?? defaultName, kind: .container, cpuCount: defaultCPUs,
                 memoryGiB: defaultMemoryGiB, diskGiB: defaultDiskGiB,
                 imageReference: imageReference)
    }
}
