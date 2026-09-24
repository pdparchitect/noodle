import Foundation

public enum ComputerKind: String, Codable, CaseIterable, Sendable {
    case macOS, linux, container, localMac

    // TODO(0.15.0): Remove this decoder and testOmarchyRecordsLoadAsLinux. The Omarchy
    // preset ran the same EFI machine as Linux, so its records load as Linux.
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let kind = ComputerKind(rawValue: value == "omarchy" ? "linux" : value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unknown computer kind \(value)"))
        }
        self = kind
    }

    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .container: "Linux Container"
        case .localMac: "Local Mac"
        }
    }

    public var symbol: String {
        switch self {
        case .macOS: "desktopcomputer"
        case .linux: "terminal"
        case .container: "shippingbox"
        case .localMac: "person.crop.rectangle"
        }
    }

    public var detail: String {
        switch self {
        case .macOS: "A private Mac with its own desktop. Automatically downloads the latest compatible macOS from Apple (several GB)."
        case .linux: "An Alpine Linux virtual machine with a command-line console. Automatically downloads the ARM64 installer; no graphical desktop included."
        case .container: ContainerRegistry.bundled.defaultTemplate.description
        case .localMac: "A separate standard account on this Mac, with its own desktop and files. Shares this Mac’s operating system and resources. One-time administrator setup is required."
        }
    }
}

public enum DefaultLinuxInstaller {
    public static let url = URL(string: "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/alpine-virt-3.23.5-aarch64.iso")!
    // Published by Alpine beside this versioned installer.
    public static let sha256 = "4fe6f6d17cbdf3b52b618cb793e77b4bfe47de33572cd6577dd1823f96e337ba"
}

public struct Computer: Codable, Identifiable, Equatable, Sendable {
    public static var desktopImage: String { ComputerTemplate.desktop.imageReference }
    public static var shellImage: String { ComputerTemplate.shell.imageReference }
    public var isCustomContainer: Bool { kind == .container && customImage == true }
    public var hasDesktop: Bool { template?.type == .desktop }
    public var hasWebDisplay: Bool { hasDesktop || (isCustomContainer && webPort != nil) }
    public var hasDisplay: Bool { hasWebDisplay || kind == .localMac }
    public var usesVirtualMachine: Bool { kind == .macOS || kind == .linux }
    public var template: ComputerTemplate? {
        ContainerRegistry.bundled.template(for: self)
    }
    public var displayType: String { isCustomContainer ? "Custom Container" : template?.name ?? kind.title }
    public var displaySymbol: String { isCustomContainer ? "shippingbox" : template?.symbol ?? kind.symbol }
    public static let maximumDescriptionLength = 500
    public var id: UUID
    public var name: String
    /// What the user keeps this computer for; assigned bots see it. Optional, so records
    /// written before descriptions existed decode without it.
    public var description: String?
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
    public var localMacSetupRequested: Bool?

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
        guard (description?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) <= Self.maximumDescriptionLength else {
            throw ComputerError("Enter a computer description of at most \(Self.maximumDescriptionLength) characters.")
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
        if let template, (template.requiresNetworking && !networkEnabled)
            || memoryGiB < template.minimumMemoryGiB || diskGiB < template.minimumDiskGiB {
            throw ComputerError("\(template.name) needs at least \(template.minimumMemoryGiB) GB memory and a \(template.minimumDiskGiB) GB disk\(template.requiresNetworking ? ", with networking enabled" : "").")
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

    @discardableResult public func save(_ computer: Computer) throws -> Computer {
        try computer.validate()
        let directory = directory(for: computer.id)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ComputerError("Computer storage is missing.") }
        let previous = try JSONDecoder().decode(Computer.self, from: Data(contentsOf: directory.appendingPathComponent("computer.json")))
        let saved = try Self.write(computer, to: directory)
        if previous.appearance?.backgroundFilename != saved.appearance?.backgroundFilename,
           let old = previous.appearance?.backgroundURL(in: directory) {
            try? FileManager.default.removeItem(at: old)
        }
        return saved
    }

    @discardableResult public func commit(_ computer: Computer) throws -> Computer {
        try computer.validate()
        let staging = stagingDirectory(for: computer.id)
        let saved = try Self.write(computer, to: staging)
        try FileManager.default.moveItem(at: staging, to: directory(for: computer.id))
        return saved
    }

    private static func write(_ computer: Computer, to directory: URL) throws -> Computer {
        var computer = computer
        let description = computer.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        computer.description = description?.isEmpty == false ? description : nil
        var importedURL: URL?
        do {
            if let file = computer.appearance?.backgroundFile {
                let name = "\(UUID().uuidString.lowercased()).\(file.url.pathExtension)"
                guard ComputerAppearance.validBackgroundFilename(name) else {
                    throw ComputerError("Invalid computer background file.")
                }
                let folder = directory.appendingPathComponent("Backgrounds", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(name)
                importedURL = target
                try FileManager.default.copyItem(at: file.url, to: target)
                computer.appearance?.backgroundFilename = name
                computer.appearance?.backgroundMediaKind = file.kind
                computer.appearance?.backgroundFile = nil
                computer.appearance?.backgroundImage = nil
                computer.appearance?.backgroundPreset = nil
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(computer).write(to: directory.appendingPathComponent("computer.json"), options: .atomic)
            return computer
        } catch {
            if let importedURL { try? FileManager.default.removeItem(at: importedURL) }
            throw error
        }
    }
}
