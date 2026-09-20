import AppletBridge
@testable import AppletCore
import XCTest

final class NoodletConfinementTests: XCTestCase {
    private func launch(_ root: URL, executable: String = NoodletConfinement.toolchains.values.sorted()[0], readable: [String]? = nil) -> NoodletLaunch {
        NoodletLaunch(executable: executable, arguments: [], environment: ["DYLD_FRAMEWORK_PATH": "/System/Library/Frameworks", "HOME": "/x"],
            directory: root.appendingPathComponent("Builds/A").path, readable: readable ?? [root.appendingPathComponent("Builds/A").path],
            writable: [root.appendingPathComponent("Data/A").path])
    }

    func testOnlyAppleCompilerInsideAppletStorageMayRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try NoodletConfinement.process(launch(root, executable: "/bin/sh"), within: root))
        XCTAssertThrowsError(try NoodletConfinement.process(launch(root, readable: [NSHomeDirectory()]), within: root))
        XCTAssertThrowsError(try NoodletConfinement.process(launch(root, readable: [root.path + "/Builds/../../Escape"]), within: root))
        let process = try NoodletConfinement.process(launch(root), within: root)
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/sandbox-exec")
        // sandbox-exec drops dyld variables, so they are set behind it.
        XCTAssertEqual(process.arguments?[2...3], ["/usr/bin/env", "DYLD_FRAMEWORK_PATH=/System/Library/Frameworks"])
        XCTAssertEqual(process.environment, ["HOME": "/x"])
    }

    /// Seatbelt matches resolved paths, and an Xcode selected by version is reached through a link.
    func testCompilerMayRunFromAToolchainReachedThroughALink() throws {
        guard let installed = NoodletConfinement.toolchains.sorted(by: { $0.key < $1.key }).first(where: { FileManager.default.isExecutableFile(atPath: $0.value) }) else {
            throw XCTSkip("No Apple Swift compiler is installed.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Developer")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: installed.key))

        let profile = NoodletConfinement.profile(launch(root), toolchain: link.path)
        let resolved = NoodletConfinement.path(installed.key)
        XCTAssertTrue(profile.contains("(allow process-exec (literal \"/usr/bin/env\") (subpath \"\(resolved)\"))"), profile)

        // The rule has to hold in the real sandbox too, not only read well.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, "/usr/bin/env", link.path + installed.value.dropFirst(installed.key.count), "-version"]
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("Swift version"), text)
    }

    func testDevicesFollowGrantedPermissions() {
        let root = URL(fileURLWithPath: "/tmp/applet")
        var request = launch(root)
        XCTAssertFalse(NoodletConfinement.profile(request, toolchain: "/bin").contains("device-"))
        request.devices = ["microphone", "screen-capture"]
        let profile = NoodletConfinement.profile(request, toolchain: "/bin")
        XCTAssertTrue(profile.contains("(allow device-microphone)"))
        XCTAssertFalse(profile.contains("device-camera"))
        XCTAssertTrue(profile.contains("(deny default)"))
    }

    func testProfileKeepsFilesToTheNamedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Builds/A", "Data/A", "Data/B"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: root.appendingPathComponent(folder + "/file"))
        }
        // The shell stands in for the compiler; the rules are the ones a noodlet gets.
        let profile = NoodletConfinement.profile(launch(root), toolchain: "/bin")
        func run(_ script: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, "/bin/sh", "-c", script]
            process.currentDirectoryURL = root.appendingPathComponent("Builds/A")
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let path = NoodletConfinement.path(root.path)
        XCTAssertEqual(try run("cat '\(path)/Builds/A/file' && echo own > '\(path)/Data/A/new'"), 0)
        XCTAssertNotEqual(try run("cat '\(path)/Data/B/file'"), 0, "Another noodlet's data")
        XCTAssertNotEqual(try run("echo x > '\(path)/Builds/A/file'"), 0, "The build is read-only")
        XCTAssertNotEqual(try run("ls '\(NSHomeDirectory())'"), 0, "The user's home")
        XCTAssertNotEqual(try run("cat '\(NSHomeDirectory())/Library/Keychains/login.keychain-db'"), 0, "The login Keychain")
    }
}
