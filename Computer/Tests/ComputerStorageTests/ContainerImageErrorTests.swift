import XCTest
import ComputerCore
import ContainerizationOCI
@testable import NoodleComputer

final class ContainerImageErrorTests: XCTestCase {
    func testIncompleteReferencesOfferValidCopyableCorrections() {
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let examples = [
            ("kalilinux/kali-rolling", "docker.io/kalilinux/kali-rolling:latest"),
            ("kalilinux/kali-rolling:arm64", "docker.io/kalilinux/kali-rolling:arm64"),
            ("alpine", "docker.io/library/alpine:latest"),
            ("alpine@" + digest, "docker.io/library/alpine@" + digest),
            ("docker.io/kalilinux/kali-rolling", "docker.io/kalilinux/kali-rolling:latest"),
            ("ghcr.io/example/image", "ghcr.io/example/image:latest"),
            ("localhost:5000/image", "localhost:5000/image:latest")
        ]
        for (reference, correction) in examples {
            XCTAssertThrowsError(try ContainerComputer.validateImageReference(reference)) { error in
                XCTAssertTrue(error.localizedDescription.contains(correction), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("invalid domain"))
            }
            XCTAssertNoThrow(try ContainerComputer.validateImageReference(correction))
        }
        for reference in ["ghcr.io/example/image:v1", "localhost:5000/image:v1",
                          "registry.example.com:5000/team/image@" + digest,
                          "[::1]:5000/image:latest"] {
            XCTAssertNoThrow(try ContainerComputer.validateImageReference(reference))
        }
    }

    func testMalformedReferencesExplainTheExpectedFormat() {
        for reference in ["", "https://hub.docker.com/r/kalilinux/kali-rolling", "docker pull alpine",
                          "docker.io/Bad/Image:latest", "docker.io/library/alpine:", "docker.io/image@sha256:bad"] {
            XCTAssertThrowsError(try ContainerComputer.validateImageReference(reference)) { error in
                XCTAssertTrue(error.localizedDescription.contains("docker.io/library/nginx:alpine"), error.localizedDescription)
            }
        }
    }

    @MainActor func testKaliCreationFailsBeforePreparingOrDownloading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let computer = Computer(name: "Kali", kind: .container,
                                imageReference: "kalilinux/kali-rolling", customImage: true)
        let created = await store.create(computer, source: nil)
        XCTAssertFalse(created)
        XCTAssertTrue(store.error?.contains("docker.io/kalilinux/kali-rolling:latest") == true, store.error ?? "No error")
        XCTAssertFalse(store.creationWasCancelled)
        XCTAssertNil(store.creationStatus)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.library.stagingDirectory(for: computer.id).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.cache.path).isEmpty)
    }

    func testInvalidReferenceNeverReachesTheRegistryOperation() async {
        do {
            try await ContainerComputer.registryRequest(reference: "kalilinux/kali-rolling") {
                XCTFail("An incomplete image name must not start a download")
            }
            XCTFail("An incomplete image name was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("docker.io/kalilinux/kali-rolling:latest"))
        }
    }

    func testRegistryFailuresGiveRelevantRecoveryAdvice() async {
        let reference = "docker.io/kalilinux/kali-rolling:latest"
        let manifest = "https://registry-1.docker.io/v2/kalilinux/kali-rolling/manifests/latest"
        let cases: [(RegistryClient.Error, String, String)] = [
            (.invalidStatus(url: manifest, .notFound), "Check the repository name and tag", "HTTP 404"),
            (.invalidStatus(url: "https://example.com/v2/image/blobs/sha256:abc", .notFound), "required download", "HTTP 404"),
            (.invalidStatus(url: manifest, .unauthorized), "does not currently support registry sign-in", "HTTP 401"),
            (.invalidStatus(url: manifest, .forbidden), "choose an image that allows public downloads", "HTTP 403"),
            (.invalidStatus(url: manifest, .tooManyRequests), "Wait a while and try again", "HTTP 429"),
            (.invalidStatus(url: manifest, .serviceUnavailable), "Try again later", "HTTP 503"),
            (.invalidStatus(url: manifest, .badRequest), "Check the image name and tag", "HTTP 400"),
            (.insecureCredentialExchange(message: "test detail"), "unsafe sign-in exchange", "registry administrator")
        ]
        for (failure, advice, detail) in cases {
            do {
                try await ContainerComputer.registryRequest(reference: reference) { throw failure }
                XCTFail("The failed download unexpectedly succeeded")
            } catch {
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(reference), message)
                XCTAssertTrue(message.contains(advice), message)
                XCTAssertTrue(message.contains(detail), message)
            }
        }
    }

    func testSuccessfulRequestsAndCancellationPassThrough() async throws {
        let reference = "docker.io/kalilinux/kali-rolling:latest"
        let result = try await ContainerComputer.registryRequest(reference: reference) { "downloaded" }
        XCTAssertEqual(result, "downloaded")
        do {
            try await ContainerComputer.registryRequest(reference: reference) { throw CancellationError() }
            XCTFail("Cancellation was swallowed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
