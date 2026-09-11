import XCTest
import AppKit
import SwiftUI
import ComputerCore
import Containerization
import ContainerizationOCI
import CryptoKit
@testable import NoodleComputer

final class StorageMaintenanceTests: XCTestCase {
    private func fixture() throws -> ComputerLibrary {
        try ComputerLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func write(_ path: String, in library: ComputerLibrary, text: String = "preserve me") throws {
        let file = library.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testOnlyPreviewedInstallerCachesAreRemoved() async throws {
        let library = try fixture()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let cached = "Runtime/Linux Images/" + String(repeating: "a", count: 64) + ".iso"
        try write(cached, in: library)
        try write(cached + ".json", in: library)
        let preserved = ["Runtime/initfs-0.43.0.ext4", "Runtime/unknown.ext4", "Runtime/Linux Images/user.iso",
                         "Computers/example/Layers/current/Upper.ext4", "Computers/example/Layers/previous/Upper.ext4",
                         "Computers/example/Disk.img", "Staging/unfinished/Disk.img"]
        for path in preserved { try write(path, in: library) }
        let preview = try await StorageMaintenance.inspect(library: library)
        XCTAssertGreaterThan(preview.freeBytes, 0)
        XCTAssertEqual(preview.obsoleteFiles.count, 2)
        XCTAssertGreaterThan(preview.computerBytes, 0)
        _ = try await StorageMaintenance.clean(library: library, preview: preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(cached).path))
        for path in preserved {
            XCTAssertEqual(try String(contentsOf: library.root.appendingPathComponent(path), encoding: .utf8), "preserve me")
        }
        let after = try await StorageMaintenance.inspect(library: library)
        XCTAssertFalse(after.canClean)
    }

    func testStalePreviewRefusesDeletion() async throws {
        let library = try fixture()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let cached = "Runtime/Restore Images/" + String(repeating: "b", count: 64) + ".ipsw"
        try write(cached, in: library)
        let preview = try await StorageMaintenance.inspect(library: library)
        try write(cached, in: library, text: "newly replaced download")
        do {
            _ = try await StorageMaintenance.clean(library: library, preview: preview)
            XCTFail("A changed cache must require another preview")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed since the preview")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(cached).path))
    }

    func testLinkedAndDanglingPathsAreRefused() async throws {
        let library = try fixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: library.root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("external".utf8).write(to: outside.appendingPathComponent("private.txt"))
        let runtime = library.root.appendingPathComponent("Runtime")
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: outside)
        do { _ = try await StorageMaintenance.inspect(library: library); XCTFail("Linked runtime accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("linked path")) }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("private.txt"), encoding: .utf8), "external")
        try FileManager.default.removeItem(at: runtime)
        try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: outside.appendingPathComponent("missing"))
        XCTAssertThrowsError(try StorageMaintenance.snapshot(at: runtime))
    }

    func testImageGarbageCollectionKeepsActiveAndRecoveryDigests() async throws {
        let library = try fixture()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let imagePath = library.root.appendingPathComponent("Runtime/Images")
        let content = try LocalContentStore(path: imagePath.appendingPathComponent("content"))
        let images = try ImageStore(path: imagePath)
        func seed(_ reference: String) async throws -> String {
            let data = try JSONEncoder().encode(Index(manifests: [], annotations: ["test": reference]))
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try await content.ingest { directory in try data.write(to: directory.appendingPathComponent(hex)) }
            try await images.create(description: .init(reference: reference,
                descriptor: Descriptor(mediaType: MediaTypes.index, digest: "sha256:" + hex, size: Int64(data.count))))
            return "sha256:" + hex
        }
        let active = try await seed("example.com/active:old")
        let recovery = try await seed("example.com/recovery:old")
        _ = try await seed("example.com/unused:old")
        _ = try await seed(ContainerComputer.initReference)
        var computer = ComputerTemplate.shell.makeComputer(name: "Kept")
        computer.imageReference = "example.com/active:latest"
        let directory = library.directory(for: computer.id)
        try FileManager.default.createDirectory(at: library.stagingDirectory(for: computer.id), withIntermediateDirectories: true)
        try library.commit(computer)
        let previous = ContainerDiskState(imageReference: "example.com/recovery:old", imageDigest: recovery)
        let state = ContainerDiskState(previousGeneration: previous.generation, imageReference: computer.imageReference, imageDigest: active)
        for generation in [previous, state] {
            for name in ["Base.ext4", "Upper.ext4", "Mount.ext4", "ImageConfig.json"] {
                let path = generation.directory(in: directory).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("disk".utf8).write(to: path)
            }
            try generation.activate(in: directory)
        }
        let preview = try await StorageMaintenance.inspect(library: library)
        XCTAssertEqual(preview.obsoleteImages, ["example.com/unused:old"])
        _ = try await StorageMaintenance.clean(library: library, preview: preview)
        let remaining = try await Set(images.list().map(\.reference))
        XCTAssertEqual(remaining, ["example.com/active:old", "example.com/recovery:old", ContainerComputer.initReference])
        XCTAssertEqual(try ContainerDiskState.load(in: directory), state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.directory(in: directory).appendingPathComponent("Upper.ext4").path))
        // Corrupt metadata must retain every cached image and skip blob GC.
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("ContainerDisk.json"))
        let unknown = try await StorageMaintenance.inspect(library: library)
        XCTAssertNil(unknown.protectedImages)
        XCTAssertTrue(unknown.obsoleteImages.isEmpty)
        XCTAssertEqual(unknown.orphanedBytes, 0)
    }

    @MainActor func testStorageControllerAndLayout() async throws {
        let library = try fixture()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let cached = "Runtime/Linux Images/" + String(repeating: "c", count: 64) + ".iso"
        try write(cached, in: library)
        let store = try ComputerStore(root: library.root)
        let preview = try await StorageMaintenance.inspect(library: library)
        store.storageReport = preview
        let hosting = NSHostingView(rootView: StorageView(model: store).preferredColorScheme(.dark))
        let size = hosting.fittingSize
        XCTAssertEqual(size.width, 580, accuracy: 1)
        XCTAssertGreaterThan(size.height, 200)
        XCTAssertLessThan(size.height, 650)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/noodle-computer-storage-settings.png"))
        window.orderOut(nil)
        // Appearing runs the same automatic inspection as Settings. Wait for its
        // disabled-button state to clear before exercising the cleanup action.
        let deadline = Date().addingTimeInterval(3)
        while store.storageBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.storageBusy)
        store.cleanStorage(preview: preview)
        XCTAssertTrue(store.storageCleaning)
        await store.storageTask?.value
        XCTAssertFalse(store.storageCleaning)
        XCTAssertFalse(store.storageBusy)
        XCTAssertEqual(store.storageReport?.removableCount, 0)
        XCTAssertTrue(store.storageError?.contains("preserved") == true)
    }

    @MainActor func testMaintenanceBlocksRuntimeMutations() async throws {
        let library = try fixture()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let store = try ComputerStore(root: library.root)
        let session = ComputerSession(ComputerTemplate.shell.makeComputer(name: "Blocked"))
        store.storageCleaning = true
        await store.start(session)
        XCTAssertEqual(session.phase, .stopped)
        await store.updateImage(session)
        XCTAssertTrue(store.imageUpdateTasks.isEmpty)
        let created = await store.create(session.computer, source: nil)
        XCTAssertFalse(created)
    }
}
