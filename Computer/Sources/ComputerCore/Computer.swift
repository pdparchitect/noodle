import Foundation

public enum ComputerKind: String, Codable, CaseIterable, Sendable {
    case macOS, linux, container, omarchy

    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .container: "Linux Container"
        case .omarchy: "Omarchy · Experimental"
        }
    }

    public var symbol: String {
        switch self {
        case .macOS: "desktopcomputer"
        case .linux: "terminal"
        case .container: "shippingbox"
        case .omarchy: "square.grid.3x3"
        }
    }

    public var detail: String {
        switch self {
        case .macOS: "A private Mac with its own desktop. Automatically downloads the latest compatible macOS from Apple (several GB)."
        case .linux: "An Alpine Linux virtual machine with a command-line console. Automatically downloads the ARM64 installer; no graphical desktop included."
        case .container: "A ready-to-use Linux desktop with a browser, terminal and file manager, based on Launcher. Downloads about 540 MB."
        case .omarchy: "Experimental custom Linux preset. Choose an ARM64 Omarchy installer in Advanced Options. No verified default image is available; a standard x86-64 ISO will not boot."
        }
    }
}

public enum DefaultLinuxInstaller {
    public static let url = URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/alpine-virt-3.23.5-aarch64.iso")!
    // Published by Alpine beside this versioned installer.
    public static let sha256 = "4fe6f6d17cbdf3b52b618cb793e77b4bfe47de33572cd6577dd1823f96e337ba"
}

public struct Computer: Codable, Identifiable, Equatable, Sendable {
    public static let desktopImage = "ghcr.io/pdparchitect/noodle-desktop@sha256:8d913cfb33c6a09a2a54c7153c3c5e7d44e6f69df0babe46a87df32d42bfde99"
    public static let shellImage = "ghcr.io/pdparchitect/noodle-shell@sha256:606d755cddf98f5c3adc5090111f4b41fffbba811c9096ce63c846845fb0970f"
    // Saved computers keep their original rootfs and image reference across upgrades.
    private static let desktopImages = [desktopImage, "ghcr.io/pdparchitect/launcher-image-base-desktop@sha256:1c6eeebbdfbbd00426a60e8284b9ffa9ec0619166efeeca179ac5eb132f1f061"]
    private static let shellImages = [shellImage, "docker.io/library/alpine:3.23.5"]
    public var isCustomContainer: Bool { kind == .container && customImage == true }
    public var hasDesktop: Bool { kind == .container && !isCustomContainer && Self.desktopImages.contains(imageReference) }
    public var hasWebDisplay: Bool { hasDesktop || (isCustomContainer && webPort != nil) }
    public var template: ComputerTemplate? {
        guard kind == .container, !isCustomContainer else { return nil }
        if Self.desktopImages.contains(imageReference) { return .desktop }
        if Self.shellImages.contains(imageReference) { return .shell }
        return nil
    }
    public var displayType: String { isCustomContainer ? "Custom Container" : template?.title ?? kind.title }
    public var displaySymbol: String { isCustomContainer ? "shippingbox" : template?.symbol ?? kind.symbol }
    public var id: UUID
    public var name: String
    public var kind: ComputerKind
    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var networkEnabled: Bool
    public var createdAt: Date
    public var installationComplete: Bool
    public var imageReference: String
    public var macAddress: String?
    public var customImage: Bool?
    public var webPort: Int?
    public var appearance: ComputerAppearance?

    public init(id: UUID = UUID(), name: String, kind: ComputerKind, cpuCount: Int = 4,
                memoryGiB: Int = 4, diskGiB: Int = 64, networkEnabled: Bool = true,
                createdAt: Date = .now, installationComplete: Bool = false,
                imageReference: String = Computer.shellImage, macAddress: String? = nil,
                customImage: Bool = false, webPort: Int? = nil) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.networkEnabled = networkEnabled
        self.createdAt = createdAt
        self.installationComplete = installationComplete
        self.imageReference = imageReference
        self.macAddress = macAddress
        self.customImage = customImage
        self.webPort = webPort
    }

    public func validate() throws {
        try appearance?.validate()
        guard !name.isEmpty, name.count <= 100, !name.contains(where: \.isNewline) else {
            throw ComputerError("Use a single-line name between 1 and 100 characters.")
        }
        guard (1...32).contains(cpuCount), (1...128).contains(memoryGiB), (4...2048).contains(diskGiB) else {
            throw ComputerError("CPU, memory, or disk size is outside the supported range.")
        }
        if kind == .macOS, memoryGiB < 4 || diskGiB < 64 || cpuCount < 2 {
            throw ComputerError("macOS needs at least 2 CPUs, 4 GB memory, and a 64 GB disk.")
        }
        if kind == .container, imageReference.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ComputerError("A container image is required.")
        }
        if hasDesktop && (!networkEnabled || memoryGiB < 2 || diskGiB < 8) {
            throw ComputerError("The Linux desktop needs networking, at least 2 GB memory and an 8 GB disk.")
        }
        if let webPort, !isCustomContainer || !(1...65535).contains(webPort) || !networkEnabled {
            throw ComputerError("A web display needs networking and a port between 1 and 65535 on a custom container.")
        }
        if isCustomContainer, imageReference.contains(where: \.isWhitespace) || imageReference.contains("://") {
            throw ComputerError("Enter a container image reference, such as docker.io/library/nginx:alpine, not a web URL.")
        }
    }
}

public struct ComputerError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The on-disk library is independent of UI, Virtualization, and Noodle agent data.
/// Computers are committed only after preparation, so an interrupted import cannot
/// appear as a bootable computer. A separate Staging directory holds partial work.
public struct ComputerLibrary: Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        for directory in [root, root.appendingPathComponent("Computers"), root.appendingPathComponent("Staging")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent("Computers").appendingPathComponent(id.uuidString.lowercased())
    }

    public func stagingDirectory(for id: UUID) -> URL {
        root.appendingPathComponent("Staging").appendingPathComponent(id.uuidString.lowercased())
    }

    public func load() throws -> [Computer] {
        let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Computers"), includingPropertiesForKeys: nil)
        return try entries.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { entry in
            let computer = try JSONDecoder().decode(Computer.self, from: Data(contentsOf: entry.appendingPathComponent("computer.json")))
            guard entry.lastPathComponent == computer.id.uuidString.lowercased() else {
                throw ComputerError("A computer record has a mismatched identifier: \(entry.lastPathComponent)")
            }
            try computer.validate()
            return computer
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ computer: Computer) throws {
        try computer.validate()
        let directory = directory(for: computer.id)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ComputerError("Computer storage is missing.") }
        try Self.write(computer, to: directory)
    }

    public func commit(_ computer: Computer) throws {
        try computer.validate()
        let staging = stagingDirectory(for: computer.id)
        try Self.write(computer, to: staging)
        try FileManager.default.moveItem(at: staging, to: directory(for: computer.id))
    }

    private static func write(_ computer: Computer, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(computer).write(to: directory.appendingPathComponent("computer.json"), options: .atomic)
    }
}
