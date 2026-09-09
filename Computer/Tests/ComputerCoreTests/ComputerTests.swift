import XCTest
@testable import ComputerCore

final class ComputerTests: XCTestCase {
    func testCustomImageAndWebPortValidation() throws {
        var computer = Computer(name: "Custom", kind: .container, memoryGiB: 1, diskGiB: 8,
                                imageReference: "docker.io/library/nginx:alpine", customImage: true, webPort: 80)
        XCTAssertTrue(computer.hasWebDisplay)
        XCTAssertFalse(computer.hasDesktop)
        XCTAssertNil(computer.template)
        XCTAssertNoThrow(try computer.validate())
        for port in [0, -1, 65536] {
            computer.webPort = port
            XCTAssertThrowsError(try computer.validate())
        }
        computer.webPort = 80
        computer.networkEnabled = false
        XCTAssertThrowsError(try computer.validate())
        computer.webPort = nil
        XCTAssertFalse(computer.hasWebDisplay)
        XCTAssertNoThrow(try computer.validate())
        for reference in ["", "a b", "https://example.com/image"] {
            computer.imageReference = reference
            XCTAssertThrowsError(try computer.validate())
        }
    }

    func testAppearanceRoundTripAndBounds() throws {
        var computer = ComputerTemplate.shell.makeComputer()
        var appearance = ComputerAppearance()
        appearance.iconSymbol = "bolt.fill"
        appearance.iconColour = 3
        appearance.backgroundPreset = "ocean"
        appearance.terminalForeground = "33FF99"
        appearance.terminalOpacity = 0.25
        computer.appearance = appearance
        XCTAssertNoThrow(try computer.validate())
        XCTAssertEqual(try JSONDecoder().decode(Computer.self, from: JSONEncoder().encode(computer)), computer)
        appearance.terminalOpacity = 2
        XCTAssertThrowsError(try appearance.validate())
        appearance.terminalOpacity = 0.5
        appearance.terminalForeground = "bad-colour"
        XCTAssertThrowsError(try appearance.validate())
    }
    func testV1TemplatesAreDesktopAndShellContainers() throws {
        XCTAssertEqual(ComputerTemplate.allCases.map(\.title), ["Desktop", "Shell"])
        for template in ComputerTemplate.allCases {
            let computer = template.makeComputer()
            XCTAssertEqual(computer.kind, .container)
            XCTAssertEqual(computer.template, template)
            XCTAssertEqual(computer.displayType, template.title)
            XCTAssertEqual(computer.name, template.defaultName)
            XCTAssertEqual(computer.imageReference, template.imageReference)
            XCTAssertNoThrow(try computer.validate())
            XCTAssertEqual(try JSONDecoder().decode(Computer.self,
                from: JSONEncoder().encode(computer)), computer)
        }
        let desktop = ComputerTemplate.desktop.makeComputer()
        XCTAssertTrue(desktop.hasDesktop)
        var shell = ComputerTemplate.shell.makeComputer()
        XCTAssertFalse(shell.hasDesktop)
        XCTAssertEqual(shell.imageReference, "docker.io/library/alpine:3.23.5")
        XCTAssertEqual(shell.cpuCount, 2)
        XCTAssertEqual(shell.memoryGiB, 1)
        XCTAssertEqual(shell.diskGiB, 4)
        shell.networkEnabled = false
        XCTAssertNoThrow(try shell.validate())
    }

    func testVMRecordsRemainSupportedWithoutBecomingContainerTemplates() throws {
        for kind in [ComputerKind.macOS, .linux, .omarchy] {
            let computer = Computer(name: "Existing VM", kind: kind)
            let decoded = try JSONDecoder().decode(Computer.self,
                from: JSONEncoder().encode(computer))
            XCTAssertEqual(decoded, computer)
            XCTAssertNil(decoded.template)
            XCTAssertEqual(decoded.displayType, kind.title)
            XCTAssertNoThrow(try decoded.validate())
        }
    }

    func testDesktopTemplateAndLegacyWorkspaceRemainDistinct() throws {
        let legacy = Computer(name: "Existing workspace", kind: .container)
        XCTAssertFalse(legacy.hasDesktop)
        let decoded = try JSONDecoder().decode(Computer.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.imageReference, legacy.imageReference)
        var desktop = Computer(name: "Desktop", kind: .container, memoryGiB: 4, diskGiB: 32,
                               imageReference: Computer.desktopImage)
        XCTAssertTrue(desktop.hasDesktop)
        XCTAssertNoThrow(try desktop.validate())
        desktop.networkEnabled = false
        XCTAssertThrowsError(try desktop.validate())
        desktop.networkEnabled = true
        desktop.diskGiB = 4
        XCTAssertThrowsError(try desktop.validate())
    }

    func testNameMustBeSingleLineAndNonempty() {
        for name in ["", "  ", "A\nB", String(repeating: "x", count: 101)] {
            XCTAssertThrowsError(try Computer(name: name, kind: .linux).validate())
        }
        XCTAssertNoThrow(try Computer(name: "My Linux", kind: .linux).validate())
    }

    func testResourceValidation() {
        XCTAssertThrowsError(try Computer(name: "Mac", kind: .macOS, cpuCount: 1).validate())
        XCTAssertThrowsError(try Computer(name: "Mac", kind: .macOS, memoryGiB: 2).validate())
        XCTAssertThrowsError(try Computer(name: "Mac", kind: .macOS, diskGiB: 32).validate())
        XCTAssertThrowsError(try Computer(name: "Linux", kind: .linux, diskGiB: -1).validate())
        XCTAssertThrowsError(try Computer(name: "Linux", kind: .linux, memoryGiB: 999).validate())
        XCTAssertNoThrow(try Computer(name: "Workspace", kind: .container, cpuCount: 1, memoryGiB: 1, diskGiB: 4).validate())
    }

    func testLibraryCommitReloadAndRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ComputerLibrary(root: root)
        var computer = Computer(name: "My Computer", kind: .linux)
        try FileManager.default.createDirectory(at: library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        XCTAssertTrue(try library.load().isEmpty, "Uncommitted staging must not appear in the library")
        try library.commit(computer)
        XCTAssertEqual(try library.load(), [computer])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.stagingDirectory(for: computer.id).path))
        computer.name = "Renamed"
        computer.installationComplete = true
        try library.save(computer)
        XCTAssertEqual(try ComputerLibrary(root: root).load(), [computer])
    }

    func testDuplicateCommitDoesNotOverwriteDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ComputerLibrary(root: root)
        let computer = Computer(name: "Workspace", kind: .container)
        let staging = library.stagingDirectory(for: computer.id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: staging.appendingPathComponent("disk"))
        try library.commit(computer)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertThrowsError(try library.commit(computer))
        XCTAssertEqual(try String(contentsOf: library.directory(for: computer.id).appendingPathComponent("disk"), encoding: .utf8), "keep")
    }

    func testNamesDoNotControlStoragePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ComputerLibrary(root: root)
        let computer = Computer(name: "../../outside", kind: .linux)
        XCTAssertEqual(library.directory(for: computer.id).lastPathComponent, computer.id.uuidString.lowercased())
    }
}
