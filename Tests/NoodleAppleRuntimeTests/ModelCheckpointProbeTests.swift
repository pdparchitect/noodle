#if canImport(FoundationModels, _version: 2)
import XCTest
import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import Tokenizers
@testable import NoodleCore

/// Checks each offered model against this build without downloading its
/// weights: the model is built lazily from its config and matched against the
/// safetensors headers, and its chat template is rendered with a tool.
final class ModelCheckpointProbeTests: XCTestCase {
    func testAvailableModelsLoadInThisBuild() async throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_MODEL_CHECKPOINTS"] == "1" else {
            throw XCTSkip("Set NOODLE_TEST_MODEL_CHECKPOINTS=1 to check the offered models against Hugging Face.")
        }
        var failures: [String] = []
        for model in AppleDownloadableModel.available {
            do { try await probe(model) } catch { failures.append("\(model.repository): \(error)") }
        }
        XCTAssertEqual(failures, [])
    }

    private func probe(_ model: AppleDownloadableModel) async throws {
        let names = model.files.map(\.name)
        let base = model.sourceURL.appendingPathComponent("resolve").appendingPathComponent(model.revision)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in names where !name.hasSuffix(".safetensors") {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(name))
            try data.write(to: folder.appendingPathComponent(name))
        }

        var weights: [String: MLXArray] = [:]
        var metadata: [String: String] = [:]
        for name in names where name.hasSuffix(".safetensors") {
            let header = try await safetensorsHeader(base.appendingPathComponent(name))
            for (key, value) in header {
                if key == "__metadata__" { metadata.merge(value as? [String: String] ?? [:]) { $1 }; continue }
                let entry = try XCTUnwrap(value as? [String: Any])
                let shape = try XCTUnwrap(entry["shape"] as? [Int])
                weights[key] = MLXArray.zeros(shape, dtype: try dtype(XCTUnwrap(entry["dtype"] as? String)))
            }
        }

        let configData = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        let configuration = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        let language = try await LLMTypeRegistry.shared.createModel(configuration: configData, modelType: configuration.modelType)
        weights = try language.sanitize(weights: weights, metadata: metadata)
        if let quantization = configuration.perLayerQuantization {
            quantize(model: language) { path, _ in
                weights["\(path).scales"] != nil ? quantization.quantization(layer: path)?.asTuple : nil
            }
        }
        try language.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])

        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        let tool: [String: any Sendable] = ["type": "function", "function": [
            "name": "get_weather", "description": "Current weather for a city.",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]] as [String: any Sendable],
        ] as [String: any Sendable]]
        let first = try tokenizer.applyChatTemplate(messages: [["role": "system", "content": "Be brief."],
                                                              ["role": "user", "content": "Weather in Sofia?"]], tools: [tool])
        let call: [String: any Sendable] = ["type": "function", "function": ["name": "get_weather", "arguments": ["city": "Sofia"]] as [String: any Sendable]]
        let second = try tokenizer.applyChatTemplate(messages: [
            ["role": "user", "content": "Weather in Sofia?"],
            ["role": "assistant", "content": "", "tool_calls": [call]],
            ["role": "tool", "content": "{\"temperature\": 21}"],
        ], tools: [tool])
        let tail = tokenizer.decode(tokens: Array(second.suffix(40)))
        print("PROBE \(model.repository) type=\(configuration.modelType) tensors=\(weights.count)",
              "format=\(language.toolCallFormat.map { "\($0)" } ?? "default") prompt=\(first.count)/\(second.count)",
              "footprint=\(footprint() >> 20)MB tail=\(tail.debugDescription)")
    }

    private func range(_ url: URL, _ lower: Int, _ upper: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard data.count == upper - lower + 1 else { throw ProbeError("range \(lower)-\(upper) returned \(data.count) bytes") }
        return data
    }

    private func safetensorsHeader(_ url: URL) async throws -> [String: Any] {
        let size = try await range(url, 0, 7).withUnsafeBytes { Int($0.loadUnaligned(as: UInt64.self).littleEndian) }
        let header = try await range(url, 8, 8 + size - 1)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: header) as? [String: Any])
    }

    private func dtype(_ name: String) throws -> DType {
        switch name {
        case "BOOL": .bool
        case "U8": .uint8
        case "U16": .uint16
        case "U32": .uint32
        case "U64": .uint64
        case "I8": .int8
        case "I16": .int16
        case "I32": .int32
        case "I64": .int64
        case "F16": .float16
        case "BF16": .bfloat16
        case "F32": .float32
        default: throw ProbeError("unsupported dtype \(name)")
        }
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return info.phys_footprint
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
