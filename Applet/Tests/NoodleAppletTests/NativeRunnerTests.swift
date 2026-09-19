import XCTest
@testable import NoodleApplet

final class NativeRunnerTests: XCTestCase {
    private func toolchain(platformPlugins: Bool) throws -> (root: URL, compiler: String, sdk: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let developer = root.appendingPathComponent("Platform/Developer")
        for directory in ["Toolchain/usr/bin", "Toolchain/usr/lib/swift/host/plugins", "Platform/Developer/SDKs/MacOSX.sdk"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        if platformPlugins {
            for directory in ["usr/bin", "usr/lib/swift/host/plugins"] {
                try FileManager.default.createDirectory(at: developer.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            let server = developer.appendingPathComponent("usr/bin/swift-plugin-server")
            try Data().write(to: server)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        }
        return (root, root.appendingPathComponent("Toolchain/usr/bin/swiftc").path, developer.appendingPathComponent("SDKs/MacOSX.sdk").path)
    }

    func testPluginArgumentsIncludeToolchainAndPlatformMacros() throws {
        let fixture = try toolchain(platformPlugins: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let developer = fixture.root.appendingPathComponent("Platform/Developer").path
        XCTAssertEqual(NativeRunner.pluginArguments(compiler: fixture.compiler, sdk: fixture.sdk), [
            "-plugin-path", fixture.root.appendingPathComponent("Toolchain/usr/lib/swift/host/plugins").path,
            "-disable-sandbox", "-external-plugin-path", "\(developer)/usr/lib/swift/host/plugins#\(developer)/usr/bin/swift-plugin-server",
        ])
    }

    func testPluginArgumentsOmitPlatformMacrosWithoutPluginServer() throws {
        let fixture = try toolchain(platformPlugins: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(NativeRunner.pluginArguments(compiler: fixture.compiler, sdk: fixture.sdk), [
            "-plugin-path", fixture.root.appendingPathComponent("Toolchain/usr/lib/swift/host/plugins").path,
        ])
    }
}
