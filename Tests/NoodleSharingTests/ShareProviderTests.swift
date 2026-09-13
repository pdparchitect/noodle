import AppKit
import Foundation
import NoodleCore
import UniformTypeIdentifiers
import XCTest
@testable import NoodleSharing

@MainActor final class ShareProviderTests: XCTestCase {
    private func fixture() throws -> ShareFixture {
        let f = try ShareFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }
    private func finish(_ task: Task<Void, Never>?) async throws {
        let task = try XCTUnwrap(task)
        let finished = expectation(description: "Share load completed")
        Task { await task.value; finished.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    func testNativeTextURLAndFileProvidersKeepTheirDistinctRepresentations() async throws {
        let f = try fixture(), file = try f.file("source.txt")
        let text = NSItemProvider(object: "  Shared note  " as NSString)
        let url = NSItemProvider(object: NSURL(string: "https://example.com/shared-page")!)
        let local = NSItemProvider(object: file as NSURL)
        local.suggestedName = "../../Renamed.txt"
        try await f.load([.provider(text), .provider(url), .provider(local)])
        XCTAssertNil(f.model.error)
        XCTAssertEqual(f.model.text, "Shared note\n\nhttps://example.com/shared-page")
        XCTAssertEqual(f.model.filenames, ["Renamed.txt"])
        try f.model.send()
        let request = try XCTUnwrap(f.inbox.pending().first)
        XCTAssertEqual(try f.inbox.files(for: request).map { try Data(contentsOf: $0) }, [Data("Shared bytes".utf8)])
    }

    func testBinaryProviderCopiesBytesAndSuppliesTheMissingExtension() async throws {
        let f = try fixture(), bytes = Data([0, 255, 3, 128]), file = try f.file("provider-file", bytes: bytes)
        let provider = NSItemProvider()
        provider.suggestedName = "Screenshot"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(file, false, nil)
            return nil
        }
        try await f.load([.provider(provider)])
        XCTAssertNil(f.model.error)
        XCTAssertEqual(f.model.filenames, ["Screenshot.png"])
        try FileManager.default.removeItem(at: file)
        try f.model.send()
        let request = try XCTUnwrap(f.inbox.pending().first)
        XCTAssertEqual(try f.inbox.files(for: request).map { try Data(contentsOf: $0) }, [bytes])
    }

    func testUnsupportedProviderAndNonWebURLCannotBePublished() async throws {
        for provider in [NSItemProvider(), NSItemProvider(object: NSURL(string: "javascript:alert(1)")!)] {
            let f = try fixture()
            try await f.load([.provider(provider)])
            XCTAssertNotNil(f.model.error)
            XCTAssertFalse(f.model.canSend)
            XCTAssertTrue(try f.inbox.pending().isEmpty)
        }
    }

    func testCancelledProviderResultCannotRestoreContentOrDraft() async throws {
        let f = try fixture(), gate = ShareProviderGate()
        f.model.load([.provider(gate.provider)])
        let task = f.model.loadTask
        await fulfillment(of: [gate.entered], timeout: 2)
        f.model.cancel()
        gate.resolve(Data("Late private text".utf8))
        try await finish(task)
        XCTAssertTrue(f.model.text.isEmpty)
        XCTAssertTrue(f.model.filenames.isEmpty)
        XCTAssertNil(f.model.error)
        XCTAssertFalse(f.model.canSend)
        XCTAssertTrue(try f.drafts().isEmpty)
        XCTAssertTrue(try f.inbox.pending().isEmpty)
    }

    func testCancelledProviderFailureDoesNotPublishAnErrorAfterDismissal() async throws {
        let f = try fixture(), gate = ShareProviderGate()
        f.model.load([.provider(gate.provider)])
        let task = f.model.loadTask
        await fulfillment(of: [gate.entered], timeout: 2)
        f.model.cancel()
        gate.fail()
        try await finish(task)
        XCTAssertNil(f.model.error)
        XCTAssertFalse(f.model.canSend)
        XCTAssertTrue(try f.drafts().isEmpty)
    }

    func testSupersededProviderCannotAppendToOrRemoveTheNewDraft() async throws {
        let f = try fixture(), gate = ShareProviderGate()
        f.model.load([.provider(gate.provider)])
        let oldTask = f.model.loadTask
        await fulfillment(of: [gate.entered], timeout: 2)
        let file = try f.file("current.txt")
        f.model.load([.text("Current text"), .file(file)])
        try await finish(f.model.loadTask)
        XCTAssertTrue(oldTask?.isCancelled == true)
        gate.resolve(Data("Obsolete text".utf8))
        try await finish(oldTask)
        XCTAssertEqual(f.model.text, "Current text")
        XCTAssertEqual(f.model.filenames, ["current.txt"])
        XCTAssertNil(f.model.error)
        XCTAssertTrue(f.model.canSend)
        XCTAssertEqual(try f.drafts().count, 1)
        try f.model.send()
        let request = try XCTUnwrap(f.inbox.pending().first)
        XCTAssertEqual(request.body, "Current text")
        XCTAssertEqual(try f.inbox.files(for: request).count, 1)
    }
}

@MainActor private final class ShareProviderGate {
    let entered = XCTestExpectation(description: "Provider requested data")
    private var completion: ((Data?, Error?) -> Void)?
    lazy var provider: NSItemProvider = {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { [weak self] completion in
            Task { @MainActor in
                guard let self else { completion(nil, CancellationError()); return }
                self.completion = completion
                self.entered.fulfill()
            }
            return nil
        }
        return provider
    }()
    func resolve(_ data: Data) { completion?(data, nil); completion = nil }
    func fail() { completion?(nil, NSError(domain: "Fixture provider", code: 1)); completion = nil }
}
