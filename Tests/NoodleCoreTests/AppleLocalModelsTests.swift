import XCTest
@testable import NoodleCore

final class AppleLocalModelsTests: XCTestCase {
    private func fixture(_ body: (URL, AppleLocalModelStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-model-test-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Qwen-test")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"model_type":"qwen3","max_position_embeddings":32768}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        try Data(#"{"chat_template":"{{ messages }}"}"#.utf8).write(to: source.appendingPathComponent("tokenizer_config.json"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("tokenizer.json"))
        try Data("synthetic weights".utf8).write(to: source.appendingPathComponent("model.safetensors"))
        try body(source, AppleLocalModelStore(repository: root.appendingPathComponent("Noodle")))
    }

    func testImportPublishesPrivateCopyAndRemovalLeavesSource() throws {
        try fixture { source, store in
            let imported = try store.importModel(from: source)
            XCTAssertEqual(try store.models(), [imported])
            XCTAssertEqual(imported.contextSize, 32_768)
            XCTAssertTrue(AppleLocalModelStore.validIdentifier(imported.id))
            XCTAssertTrue(imported.harnessModel.displayName.contains("MLX"))
            let copied = try store.folder(id: imported.id).appendingPathComponent("model.safetensors")
            try Data("changed source".utf8).write(to: source.appendingPathComponent("model.safetensors"))
            XCTAssertEqual(try String(contentsOf: copied), "synthetic weights")
            try store.remove(id: imported.id)
            XCTAssertTrue(try store.models().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testMissingWeightsUnsupportedModelsAndLinksAreRejectedWithoutPublishing() throws {
        try fixture { source, store in
            let weights = source.appendingPathComponent("model.safetensors")
            try FileManager.default.removeItem(at: weights)
            XCTAssertThrowsError(try store.importModel(from: source))
            let outside = source.deletingLastPathComponent().appendingPathComponent("outside")
            try Data("secret".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: outside)
            XCTAssertThrowsError(try store.importModel(from: source))
            try FileManager.default.removeItem(at: weights)
            try Data("weights".utf8).write(to: weights)
            try Data(#"{"model_type":"arbitrary","max_position_embeddings":4096}"#.utf8).write(to: source.appendingPathComponent("config.json"))
            XCTAssertThrowsError(try store.importModel(from: source))
            XCTAssertTrue(try store.models().isEmpty)
        }
    }

    func testCatalogueRejectsLinkedModelsAndTraversalIdentifiers() throws {
        try fixture { source, store in
            let model = try store.importModel(from: source)
            for id in ["../other", "mlx-../../outside", "default", model.id.uppercased()] {
                XCTAssertThrowsError(try store.folder(id: id))
            }
            let path = try store.folder(id: model.id)
            let moved = source.deletingLastPathComponent().appendingPathComponent("moved")
            try FileManager.default.moveItem(at: path, to: moved)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
            XCTAssertThrowsError(try store.model(id: model.id))
            XCTAssertTrue(try store.models().isEmpty)
        }
    }

    func testMissingAndEscapingWeightShardsAreRejected() throws {
        try fixture { source, store in
            for shard in ["missing.safetensors", "../model.safetensors"] {
                let index = ["weight_map": ["layer.weight": shard]]
                try JSONSerialization.data(withJSONObject: index).write(to: source.appendingPathComponent("model.safetensors.index.json"))
                XCTAssertThrowsError(try store.importModel(from: source))
                XCTAssertTrue(try store.models().isEmpty)
            }
        }
    }

    func testLegacyInspectionDecodesWithoutLocalModelFlag() throws {
        let inspection = try JSONDecoder().decode(AppleHarnessInspection.self, from: Data(#"{"models":[],"version":"old"}"#.utf8))
        XCTAssertNil(inspection.localModelsSupported)
    }
}
