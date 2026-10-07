import XCTest
@testable import NoodleComputer

@MainActor final class FileSelectionTests: XCTestCase {
    private actor RecordingService: ComputerFileService {
        let files: [GuestFile]
        var changes: [[String]] = []
        init(files: [GuestFile]) { self.files = files }
        func homeDirectory() async throws -> String { "/workspace" }
        func change(_ operation: String, path: String, extra: [String]) async throws { changes.append([operation, path] + extra) }
        func list(_ path: String) async throws -> [GuestFile] { path == "/workspace" ? files : [] }
        func read(_ file: GuestFile, path: String, to destination: URL, preview: Bool, progress: @escaping @Sendable (Int64) -> Void) async throws {}
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

    func testDroppingOntoADraggedFolderIsRejected() {
        let folder = file("Folder", kind: "directory"), other = file("Other", kind: "directory")
        XCTAssertNil(FileDropDestination.folder("/workspace", hovered: folder, moving: [other, folder]))
        XCTAssertEqual(FileDropDestination.folder("/workspace", hovered: other, moving: [folder, file("a.txt")]), "/workspace/Other")
    }
}
