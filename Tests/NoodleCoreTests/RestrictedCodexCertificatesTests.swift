import XCTest
import Security
@testable import NoodleCore

final class RestrictedCodexCertificatesTests: XCTestCase {
    private func fixture() throws -> AgentStorageLayout {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: "Certificates")
        return repository.storage(for: bot.agent.id)
    }

    func testExportsPublicSystemAnchorsAsValidPEMOutsideWritableWorkspace() throws {
        let layout = try fixture()
        let anchors = try RestrictedCodexCertificates.systemAnchors()
        let bundle = try RestrictedCodexCertificates.prepare(workspace: layout.workspace, anchors: { anchors })
        XCTAssertEqual(bundle.deletingLastPathComponent(), layout.runtime)
        let pem = try String(contentsOf: bundle, encoding: .utf8)
        let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----\n").dropFirst()
        XCTAssertEqual(blocks.count, anchors.count)
        for (block, anchor) in zip(blocks, anchors) {
            let base64 = try XCTUnwrap(block.components(separatedBy: "\n-----END CERTIFICATE-----").first)
            let data = try XCTUnwrap(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
            XCTAssertEqual(data, anchor)
            XCTAssertNotNil(SecCertificateCreateWithData(nil, data as CFData))
        }

        let account = RestrictedHarnessStorage.home(workspace: layout.workspace).appendingPathComponent(".codex")
        let temp = layout.workspace.appendingPathComponent(".noodle/tmp")
        for directory in [account, temp] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let profile = RestrictedAgentSandbox.profile(workspace: layout.workspace,
            repository: layout.package.deletingLastPathComponent().deletingLastPathComponent(),
            codexHome: account, executableDirectory: URL(fileURLWithPath: "/usr/bin"),
            application: URL(fileURLWithPath: "/usr/bin"), temporary: temp)
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/bin/sh", "-c", """
            set -eu
            /bin/cat "$1" > /dev/null
            if printf forged > "$1"; then exit 11; fi
            if /bin/rm "$1"; then exit 12; fi
            printf forged > "$2/replacement.pem"
            if /bin/mv "$2/replacement.pem" "$1"; then exit 13; fi
            """, "probe", bundle.path, layout.workspace.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try String(contentsOf: bundle, encoding: .utf8), pem)
    }

    func testFailedCertificateExportPreservesPreviousBundle() throws {
        let layout = try fixture()
        let certificate = try XCTUnwrap(RestrictedCodexCertificates.systemAnchors().first)
        let bundle = try RestrictedCodexCertificates.prepare(workspace: layout.workspace, anchors: { [certificate] })
        let original = try Data(contentsOf: bundle)
        for invalid in [[Data](), [Data()], [Data("invalid certificate".utf8)], Array(repeating: certificate, count: 2049)] {
            XCTAssertThrowsError(try RestrictedCodexCertificates.prepare(workspace: layout.workspace, anchors: { invalid }))
            XCTAssertEqual(try Data(contentsOf: bundle), original)
        }
        XCTAssertThrowsError(try RestrictedCodexCertificates.prepare(workspace: layout.workspace, anchors: {
            throw CocoaError(.fileReadNoPermission)
        }))
        XCTAssertEqual(try Data(contentsOf: bundle), original)
    }

    func testRedirectedRuntimeCannotReceiveCertificateBundle() throws {
        let layout = try fixture()
        let certificate = try XCTUnwrap(RestrictedCodexCertificates.systemAnchors().first)
        try FileManager.default.removeItem(at: layout.runtime)
        try FileManager.default.createSymbolicLink(at: layout.runtime, withDestinationURL: layout.workspace)
        XCTAssertThrowsError(try RestrictedCodexCertificates.prepare(workspace: layout.workspace, anchors: { [certificate] }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.workspace.appendingPathComponent("codex-ca-certificates.pem").path))
    }
}
