import XCTest
@testable import ComputerCore

final class ContainerDiskStateTests: XCTestCase {
    func testOnlyCompleteGenerationCanReplaceActiveDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ContainerDiskState(imageReference: Computer.shellImage, imageDigest: "old")
        try prepare(original, in: root)
        try original.activate(in: root)
        let candidate = ContainerDiskState(previousGeneration: original.generation,
                                           imageReference: Computer.shellImage, imageDigest: "new")
        XCTAssertThrowsError(try candidate.activate(in: root))
        XCTAssertEqual(try ContainerDiskState.load(in: root), original)
        try prepare(candidate, in: root)
        XCTAssertEqual(try ContainerDiskState.load(in: root), original, "Staging must not switch the live disk")
        try candidate.activate(in: root)
        XCTAssertEqual(try ContainerDiskState.load(in: root), candidate)
        XCTAssertEqual(candidate.previousGeneration, original.generation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.directory(in: root).appendingPathComponent("Upper.ext4").path))
        try original.activate(in: root)
        XCTAssertEqual(try ContainerDiskState.load(in: root), original, "The complete previous disk can be restored")
    }

    func testMissingAndCorruptLayoutFailWithoutCreatingOrReplacingDisks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("existing data".utf8).write(to: root.appendingPathComponent("Rootfs.ext4"))
        XCTAssertThrowsError(try ContainerDiskState.load(in: root))
        try Data("invalid".utf8).write(to: root.appendingPathComponent("ContainerDisk.json"))
        XCTAssertThrowsError(try ContainerDiskState.load(in: root))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Rootfs.ext4"), encoding: .utf8), "existing data")
    }

    private func prepare(_ state: ContainerDiskState, in root: URL) throws {
        let directory = state.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["Base.ext4", "Upper.ext4", "Mount.ext4", "ImageConfig.json"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
    }
}
