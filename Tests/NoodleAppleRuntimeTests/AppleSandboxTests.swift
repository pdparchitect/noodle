import XCTest
import Darwin
import NoodleCore
import NoodleAppleRuntime

final class AppleSandboxTests: XCTestCase {
    func testRestrictedNetworkCannotReachAnOtherwiseWorkingLocalServer() throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { close(server) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, length) }
        }, 0)
        XCTAssertEqual(listen(server, 1), 0)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }, 0)
        let url = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/"
        let served = expectation(description: "unrestricted request reached fixture")
        DispatchQueue.global().async {
            let connection = accept(server, nil, nil)
            if connection >= 0 {
                var buffer = [UInt8](repeating: 0, count: 4_096)
                _ = read(connection, &buffer, buffer.count)
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                response.withCString { _ = Darwin.write(connection, $0, response.utf8.count) }
                close(connection)
            }
            served.fulfill()
        }
        func fetch(restricted: Bool, localModel: Bool = false) throws -> Int32 {
            let child = Process()
            let args = ["--silent", "--fail", "--noproxy", "*", "--max-time", "2", url]
            if restricted {
                child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                child.arguments = ["-p", AppleAgentSandbox.profile(application: project, localModel: localModel), "/usr/bin/curl"] + args
            } else { child.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); child.arguments = args }
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            return child.terminationStatus
        }
        XCTAssertNotEqual(try fetch(restricted: true), 0)
        XCTAssertNotEqual(try fetch(restricted: true, localModel: true), 0)
        XCTAssertEqual(try fetch(restricted: false), 0)
        wait(for: [served], timeout: 3)
    }

    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var helper: URL {
        ProcessInfo.processInfo.environment["NOODLE_APPLE_TEST_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? project.appendingPathComponent(".build/debug/NoodleAppleAgent")
    }

    private var application: URL {
        helper.deletingLastPathComponent().lastPathComponent == "Helpers"
            ? helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : helper.deletingLastPathComponent()
    }

    func testLocalModelGrantAllowsReadingButNotChangingWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-grant-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let weights = models.appendingPathComponent("weights.txt")
        let outside = root.appendingPathComponent("secret.txt")
        try Data("weights".utf8).write(to: weights)
        try Data("secret".utf8).write(to: outside)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", AppleAgentSandbox.profile(application: project.appendingPathComponent(".build"), modelsDirectory: models, localModel: true),
            "/bin/sh", "-c", "cat \"$1\" || exit 10; if printf changed > \"$1\"; then exit 11; fi; if cat \"$2\"; then exit 12; fi; exit 0", "probe", weights.path, outside.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: weights), "weights")
    }

    func testAvailabilityThroughSeparateSandbox() throws {
        let result = try AppleHarnessProbe.inspect(executable: helper, application: application)
        XCTAssertEqual(result.models.map(\.id), ["default"])
        XCTAssertEqual(result.unavailableReason, AppleModel.inspection(version: "test").unavailableReason)
    }

    func testMetalDelegationCannotGrantWeightsOrOutsideFiles() throws {
        guard #available(macOS 27, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("metal-delegation-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("application")
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        let weights = model.appendingPathComponent("weights.txt")
        try Data("outside".utf8).write(to: outside)
        try Data("weights".utf8).write(to: weights)
        let link = app.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let source = app.appendingPathComponent("probe.c")
        let binary = app.appendingPathComponent("probe")
        try """
        #include <dlfcn.h>
        #include <stdint.h>
        #include <limits.h>
        #include <stdio.h>
        #include <errno.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        typedef char *(*issue_fn)(const char *, const char *, uint32_t);
        int main(int argc, char **argv) {
            issue_fn issue = (issue_fn)dlsym(RTLD_DEFAULT, "sandbox_extension_issue_file");
            if (!issue || argc != 5) return 10;
            char cache[PATH_MAX], resolved[PATH_MAX];
            confstr(_CS_DARWIN_USER_CACHE_DIR, cache, sizeof(cache));
            strlcat(cache, "/com.pdparchitect.noodle.apple-agent/com.apple.metalfe", sizeof(cache));
            if (realpath(cache, resolved)) {
                char *grant = issue("com.apple.app-sandbox.read-write", resolved, 0);
                if (!grant) { fprintf(stderr, "Canonical cache grant failed: %s (%d)\\n", resolved, errno); return 30; }
                free(grant);
                grant = issue("com.apple.app-sandbox.read-write", cache, 0);
                if (!grant) { fprintf(stderr, "Raw cache grant failed: %s (%d)\\n", cache, errno); return 31; }
                free(grant);
            }
            char *token = issue("com.apple.app-sandbox.read", argv[1], 0);
            if (!token) return 11;
            free(token);
            if ((token = issue("com.apple.app-sandbox.read-write", argv[1], 0))) { free(token); return 12; }
            for (int i = 2; i < argc; i++) {
                if ((token = issue("com.apple.app-sandbox.read", argv[i], 0))) { free(token); return 13 + i; }
                if ((token = issue("com.apple.app-sandbox.read-write", argv[i], 0))) { free(token); return 20 + i; }
            }
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.environment = ProcessInfo.processInfo.environment.filter { $0.key != "SDKROOT" }
        compiler.arguments = ["--sdk", "macosx", "clang", source.path, "-o", binary.path]
        try compiler.run(); compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { return XCTFail("Could not compile the sandbox probe") }
        let child = Process(), errors = Pipe()
        child.standardError = errors
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let policy = AppleAgentSandbox.profile(application: app, modelsDirectory: model, localModel: true)
        child.arguments = ["-p", policy,
                           binary.path, app.path, weights.path, outside.path, link.path]
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testRestrictedFilesystemAndCommandDescendants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-sandbox-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let bot = try repository.createAgent(named: "Boundary")
        let other = try repository.createAgent(named: "Other")
        let privateFile = repository.directory(for: other.agent).appendingPathComponent("private.txt")
        try Data("other bot".utf8).write(to: privateFile)
        let broker = MessengerBroker(repository: repository)
        try broker.start(agents: [bot.agent, other.agent])
        defer { broker.stop() }
        let layout = repository.storage(for: bot.agent.id)
        let protected = root.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: protected)
        let policy = AppleAgentSandbox.profile(application: application, workspace: layout.workspace, repository: repository.rootURL)
        let messenger = helper.deletingLastPathComponent().appendingPathComponent(helper.deletingLastPathComponent().lastPathComponent == "Helpers" ? "messenger" : "NoodleMessenger")
        let child = Process(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = ["-p", policy, "/bin/sh", "-c", """
        set -eu
        printf allowed > "$1/allowed.txt"
        if cat "$2"; then exit 11; fi
        if printf changed > "$2"; then exit 12; fi
        if printf changed > "$3"; then exit 13; fi
        if touch "$4/forged"; then exit 14; fi
        ln -s "$2" "$1/link"
        if cat "$1/link"; then exit 15; fi
        if /bin/sh -c 'cat "$1"' nested "$2"; then exit 16; fi
        if cat "$5"; then exit 17; fi
        if cat "$6/conversation.json"; then exit 18; fi
        if printf changed > "$6/messages.json"; then exit 19; fi
        "$7" --agent-directory "$1" --list-conversations > "$1/conversations.json"
        """, "probe", layout.workspace.path, protected.path, layout.configuration.path, layout.runtime.path, privateFile.path,
            repository.conversationDirectory(id: bot.conversation.id).path, messenger.path]
        child.standardError = errors
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "secret")
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("allowed.txt"), encoding: .utf8), "allowed")
    }
}
