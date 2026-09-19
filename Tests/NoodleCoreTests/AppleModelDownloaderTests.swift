import CryptoKit
import XCTest
@testable import NoodleCore

final class AppleModelDownloaderTests: XCTestCase {
    private let payloads: [String: Data] = [
        "config.json": Data(#"{"model_type":"qwen3","max_position_embeddings":32768}"#.utf8),
        "tokenizer_config.json": Data(#"{"chat_template":"{{ messages }}"}"#.utf8),
        "tokenizer.json": Data("{}".utf8),
        "model.safetensors": Data("test model weights".utf8)
    ]

    private var downloadable: AppleDownloadableModel {
        .init(name: "Test model", summary: "Test", memory: 8, repository: "mlx-community/test-model", revision: String(repeating: "a", count: 40),
              files: payloads.keys.sorted().map { name in
                  let data = payloads[name]!
                  return .init(name: name, byteCount: Int64(data.count),
                               digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
              })
    }

    private func fixture(_ body: (AppleLocalModelStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-download-test-\(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(AppleLocalModelStore(directory: directory))
    }

    func testDownloadImportsVerifiedResourcesAndRemembersSource() async throws {
        let payloads = payloads
        let downloadable = downloadable
        try await fixture { store in
            let downloader = AppleModelDownloader { url, destination, size, progress in
                XCTAssertTrue(url.path.contains("/resolve/\(downloadable.revision)/"))
                let data = try XCTUnwrap(payloads[url.lastPathComponent])
                XCTAssertEqual(Int64(data.count), size)
                try data.write(to: destination)
                progress(size)
            }
            let model = try await downloader.download(downloadable, into: store)
            XCTAssertEqual(model.sourceRepository, downloadable.repository)
            XCTAssertEqual(try store.models(), [model])
            XCTAssertEqual(try Data(contentsOf: store.folder(id: model.id).appendingPathComponent("model.safetensors")),
                           payloads["model.safetensors"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [model.id])
            let noNetwork = AppleModelDownloader { _, _, _, _ in XCTFail("Already installed model was downloaded again") }
            let existing = try await noNetwork.download(downloadable, into: store)
            XCTAssertEqual(existing.id, model.id)
        }
    }

    func testCorruptionFailureAndCancellationCleanStagingWithoutPublishing() async throws {
        let payloads = payloads
        for failure in ["checksum", "truncated", "network", "cancel"] {
            try await fixture { store in
                let downloader = AppleModelDownloader { url, destination, _, _ in
                    var data = try XCTUnwrap(payloads[url.lastPathComponent])
                    if url.lastPathComponent == "model.safetensors" {
                        switch failure {
                        case "checksum": data[0] ^= 1
                        case "truncated": data.removeLast()
                        case "network": throw URLError(.networkConnectionLost)
                        default: throw CancellationError()
                        }
                    }
                    try data.write(to: destination)
                }
                do {
                    _ = try await downloader.download(downloadable, into: store)
                    XCTFail("Expected \(failure) to fail")
                } catch {
                    if failure == "cancel" { XCTAssertTrue(error is CancellationError) }
                }
                XCTAssertTrue(try store.models().isEmpty)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
            }
        }
    }

    func testVerifiedButIncompatibleModelStillUsesImporterValidation() async throws {
        var invalidPayloads = payloads
        invalidPayloads["config.json"] = Data(#"{"model_type":"unknown","max_position_embeddings":32768}"#.utf8)
        let invalidFiles = invalidPayloads.map { name, data in
            AppleDownloadableModel.File(name: name, byteCount: Int64(data.count),
                digest: .sha256(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        let invalid = AppleDownloadableModel(name: "Invalid", summary: "Test", memory: 8, repository: downloadable.repository,
                                               revision: downloadable.revision, files: invalidFiles)
        let contents = invalidPayloads
        try await fixture { store in
            let downloader = AppleModelDownloader { url, destination, _, _ in
                try XCTUnwrap(contents[url.lastPathComponent]).write(to: destination)
            }
            do {
                _ = try await downloader.download(invalid, into: store)
                XCTFail("Unsupported architecture was published")
            } catch {}
            XCTAssertTrue(try store.models().isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
        }
    }

    func testGitBlobChecksumAndDownloadHostPolicy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello\n".utf8).write(to: url)
        try AppleModelDownloader.verify(url, file: .init(name: "sample.txt", byteCount: 6,
            digest: .gitSHA1("ce013625030ba8dba906f756967f9e9ca394464a")))
        for allowed in ["https://huggingface.co/model", "https://cdn-lfs.hf.co/weights", "https://cas-bridge.xethub.hf.co/weights"] {
            XCTAssertTrue(ModelDownloadDelegate.allows(URL(string: allowed)!))
        }
        for denied in ["http://huggingface.co/model", "https://huggingface.co.evil.test/model", "https://evil.test/weights",
                       "file:///tmp/weights", "https://user:password@huggingface.co/model", "https://huggingface.co:8080/model"] {
            XCTAssertFalse(ModelDownloadDelegate.allows(URL(string: denied)!))
        }
    }

    func testAvailableModelsHavePinnedCompatibleResources() {
        XCTAssertFalse(AppleDownloadableModel.available.isEmpty)
        XCTAssertEqual(AppleDownloadableModel.available.map(\.byteCount), AppleDownloadableModel.available.map(\.byteCount).sorted())
        XCTAssertEqual(Set(AppleDownloadableModel.available.map(\.repository)).count, AppleDownloadableModel.available.count)
        XCTAssertEqual(AppleDownloadableModel.available.map(\.memory), AppleDownloadableModel.available.map(\.memory).sorted())
        let recommended = { (gigabytes: UInt64) in AppleDownloadableModel.recommended(forPhysicalMemory: gigabytes << 30)?.name }
        XCTAssertEqual(recommended(8), "Qwen3 4B Instruct")
        XCTAssertEqual(recommended(16), "Qwen3 8B")
        XCTAssertEqual(recommended(18), "Qwen3 8B")
        XCTAssertEqual(recommended(24), "Qwen3 14B")
        XCTAssertEqual(recommended(128), "Qwen3 14B")
        XCTAssertEqual(recommended(4), "Qwen3 1.7B")
        for model in AppleDownloadableModel.available {
            XCTAssertNotNil(model.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
            XCTAssertTrue(model.repository.hasPrefix("mlx-community/"))
            XCTAssertFalse(model.summary.isEmpty)
            XCTAssertLessThanOrEqual(model.summary.count, 120)
            let names = Set(model.files.map(\.name))
            XCTAssertEqual(names.count, model.files.count)
            XCTAssertTrue(names.isSuperset(of: ["config.json", "tokenizer.json", "tokenizer_config.json"]))
            XCTAssertTrue(names.contains { $0.hasSuffix(".safetensors") })
            for file in model.files {
                XCTAssertGreaterThan(file.byteCount, 0)
                switch file.digest {
                case .sha256(let hash): XCTAssertNotNil(hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
                case .gitSHA1(let hash): XCTAssertNotNil(hash.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
                }
            }
        }
    }

    func testLiveDownloadTransportAndCancellation() async throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_MODEL_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set NOODLE_TEST_MODEL_DOWNLOAD=1 for a small Hugging Face transfer and cancellation probe.")
        }
        let model = try XCTUnwrap(AppleDownloadableModel.available.first)
        let config = try XCTUnwrap(model.files.first { $0.name == "config.json" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-model-download-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = model.sourceURL.appendingPathComponent("resolve").appendingPathComponent(model.revision)
        let destination = root.appendingPathComponent(config.name)
        try await AppleModelDownloader.fetchResource(base.appendingPathComponent(config.name), destination: destination,
                                                      byteCount: config.byteCount, progress: { _ in })
        try AppleModelDownloader.verify(destination, file: config)

        let weights = try XCTUnwrap(model.files.first { $0.name.hasSuffix(".safetensors") })
        let partial = root.appendingPathComponent(weights.name)
        let started = expectation(description: "Download reports progress")
        started.assertForOverFulfill = false
        let download = Task {
            do {
                try await AppleModelDownloader.fetchResource(base.appendingPathComponent(weights.name), destination: partial,
                                                              byteCount: weights.byteCount) { bytes in
                    if bytes > 0 { started.fulfill() }
                }
            } catch {
                if !Task.isCancelled {
                    XCTFail("Transfer failed before cancellation: \(error)")
                    started.fulfill()
                }
                throw error
            }
        }
        await fulfillment(of: [started], timeout: 30)
        download.cancel()
        do { try await download.value; XCTFail("Cancelled transfer completed") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
}
