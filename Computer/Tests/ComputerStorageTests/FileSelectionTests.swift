import XCTest
@testable import NoodleComputer

@MainActor final class FileSelectionTests: XCTestCase {
    private actor RecordingService: ComputerFileService {
        let files: [GuestFile]
        let folders: [String: [GuestFile]]
        var changes: [[String]] = []
        init(files: [GuestFile], folders: [String: [GuestFile]] = [:]) { self.files = files; self.folders = folders }
        func homeDirectory() async throws -> String { "/workspace" }
        func change(_ operation: String, path: String, extra: [String]) async throws { changes.append([operation, path] + extra) }
        func list(_ path: String) async throws -> [GuestFile] { path == "/workspace" ? files : folders[path] ?? [] }
        func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {
            try Data(repeating: 7, count: Int(file.size)).write(to: destination)
        }
        func createImportDirectory(_ path: String) async throws {}
        func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) async -> Void) async throws {}
    }
    private func file(_ name: String, kind: String = "file") -> GuestFile {
        GuestFile(name: name, kind: kind, size: 1, modified: 0, version: "v")
    }
    private func loaded(_ service: RecordingService) async throws -> ComputerFilesModel {
        let model = ComputerFilesModel(service: service, computerID: UUID())
        model.navigate("/workspace")
        try await idle(model)
        return model
    }
    private func idle(_ model: ComputerFilesModel) async throws {
        for _ in 0..<200 where model.loading || model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.loading || model.busy)
    }

    func testFilesWithoutAWorkspaceOpenAtHome() async throws {
        let service = RecordingService(files: [], folders: ["/workspace": [file("x")], "/C/Users/noodle": [file("Desktop", kind: "directory")]])
        let windows = ComputerFilesModel(service: HomeService(base: service), computerID: UUID(), workspace: nil)
        windows.appear(); try await idle(windows)
        XCTAssertEqual(windows.folder, "/C/Users/noodle")
        XCTAssertNil(windows.error)
        XCTAssertEqual(windows.files.map(\.name), ["Desktop"])
        // Coming back keeps the folder it was in.
        windows.navigate("/C"); try await idle(windows)
        windows.appear(); try await idle(windows)
        XCTAssertEqual(windows.folder, "/C")

        let linux = ComputerFilesModel(service: service, computerID: UUID())
        linux.appear(); try await idle(linux)
        XCTAssertEqual(linux.folder, "/workspace")
    }
    private struct HomeService: ComputerFileService {
        let base: RecordingService
        func homeDirectory() async throws -> String { "/C/Users/noodle" }
        func change(_ operation: String, path: String, extra: [String]) async throws {}
        func list(_ path: String) async throws -> [GuestFile] { try await base.list(path) }
        func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {}
        func createImportDirectory(_ path: String) async throws {}
        func upload(_ source: URL, to path: String, progress: @escaping @Sendable (Int64) async -> Void) async throws {}
    }

    func testActionsApplyToEveryChosenItem() async throws {
        let service = RecordingService(files: [file("a.txt"), file("b.txt"), file("Folder", kind: "directory"), file("c.txt")])
        let model = try await loaded(service)
        model.select(["c.txt", "a.txt"])
        XCTAssertEqual(model.selectedFiles.map(\.name), ["a.txt", "c.txt"])
        XCTAssertNil(model.selected, "Rename, preview and Quick Look need a single item")

        model.duplicateSelected(); try await idle(model)
        model.select(["a.txt", "c.txt"]); model.move(model.selectedFiles, intoFolder: "/workspace/Folder"); try await idle(model)
        model.select(["a.txt", "Folder"]); model.removeSelected(); try await idle(model)
        let changes = await service.changes
        XCTAssertEqual(changes, [
            ["copy", "/workspace/a.txt", "v", "/workspace/Copy of a.txt"],
            ["copy", "/workspace/c.txt", "v", "/workspace/Copy of c.txt"],
            ["rename", "/workspace/a.txt", "/workspace/Folder/a.txt"],
            ["rename", "/workspace/c.txt", "/workspace/Folder/c.txt"],
            ["remove", "/workspace/a.txt"],
            ["remove", "/workspace/Folder"]
        ])
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testExportingSeveralItemsPutsEachInTheChosenFolder() async throws {
        let service = RecordingService(files: [file("a.txt"), file("b.txt"), file("c.txt")])
        let model = try await loaded(service), destination = try folder()
        model.select(["a.txt", "c.txt"])
        model.exportSelected(into: destination); try await idle(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), ["a.txt", "c.txt"])
    }

    func testDraggingSeveralItemsOutExportsEachInTurn() async throws {
        let service = RecordingService(files: [file("a.txt"), file("b.txt")])
        let model = try await loaded(service), destination = try folder()
        var results: [String: Error?] = [:]
        for name in ["a.txt", "b.txt"] {
            model.promisedExport(file(name), path: "/workspace/" + name, to: destination.appendingPathComponent(name)) { results[name] = $0 }
        }
        try await idle(model)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.values.allSatisfy { $0 == nil }, "\(results)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), ["a.txt", "b.txt"])
    }

    func testDeletingSeveralItemsRemovesNothingWhenAFolderIsNotEmpty() async throws {
        let service = RecordingService(files: [file("a.txt"), file("Empty", kind: "directory"), file("Full", kind: "directory")],
                                       folders: ["/workspace/Full": [file(".hidden")]])
        let model = try await loaded(service)
        model.select(["a.txt", "Empty", "Full"]); model.removeSelected(); try await idle(model)
        XCTAssertNotNil(model.error)
        let changes = await service.changes
        XCTAssertEqual(changes, [])
    }

    func testRightClickingAnUnselectedItemSelectsOnlyThatItem() async throws {
        let service = RecordingService(files: [file("a.txt"), file("b.txt"), file("c.txt")])
        let model = try await loaded(service)
        model.select(["a.txt", "c.txt"])
        model.prepareContextMenu(for: model.files[0])
        XCTAssertEqual(model.selection, ["a.txt", "c.txt"], "Right-clicking inside the selection keeps it")
        model.prepareContextMenu(for: model.files[1])
        XCTAssertEqual(model.selection, ["b.txt"])
        model.prepareContextMenu(for: nil)
        XCTAssertEqual(model.selection, [], "Right-clicking empty space leaves nothing to act on")
    }

    func testActionsSkipChosenItemsThatAreNoLongerShown() async throws {
        let service = RecordingService(files: [file("a.txt"), file("b.txt"), file(".hidden")])
        let model = try await loaded(service)
        model.showHidden = true
        model.select(["a.txt", "b.txt", ".hidden"])
        model.showHidden = false; model.filter = "a"
        XCTAssertEqual(model.selectedFiles.map(\.name), ["a.txt"])
        XCTAssertEqual(model.selected?.name, "a.txt")
        model.removeSelected(); try await idle(model)
        let changes = await service.changes
        XCTAssertEqual(changes, [["remove", "/workspace/a.txt"]])
    }

    func testArrowKeysMoveFromTheEdgeOfASelection() {
        let move = { (key: UInt16, selected: Set<Int>) in FileGridNavigation.target(from: selected, keyCode: key, columns: 3, count: 10) }
        XCTAssertEqual(move(124, [2, 5]), 6, "Right moves past the last item")
        XCTAssertEqual(move(125, [2, 5]), 8, "Down moves below the last item")
        XCTAssertEqual(move(123, [2, 5]), 1, "Left moves before the first item")
        XCTAssertEqual(move(126, [2, 5]), 0, "Up stops at the top")
        XCTAssertEqual(move(124, [9]), 9)
        XCTAssertEqual(move(124, []), 0)
    }

    func testDroppingOntoADraggedFolderIsRejected() {
        let folder = file("Folder", kind: "directory"), other = file("Other", kind: "directory")
        XCTAssertNil(FileDropDestination.folder("/workspace", hovered: folder, moving: [other, folder]))
        XCTAssertEqual(FileDropDestination.folder("/workspace", hovered: other, moving: [folder, file("a.txt")]), "/workspace/Other")
    }
}
