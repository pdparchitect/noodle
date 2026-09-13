import XCTest
@testable import NoodleCore

final class RestrictedAgentSandboxTests: XCTestCase {
    func testInstalledCodexCanInitializeWithAnIsolatedAccountDirectory() throws {
        let candidates = [URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                          URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")]
        guard let installed = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("Codex is not installed")
        }
        let executable = installed.resolvingSymlinksInPath()
        let installation = executable.deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let bot = try repository.createAgent(named: "Startup probe")
        let workspace = repository.directory(for: bot.agent)
        let account = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".codex"), temp = workspace.appendingPathComponent(".noodle/tmp")
        for directory in [account, temp] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let policy = RestrictedAgentSandbox.profile(workspace: workspace, repository: repository.rootURL,
            codexHome: account, executableDirectory: installation,
            application: installation, temporary: temp)
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", policy, executable.path, "app-server"]
        process.currentDirectoryURL = workspace
        process.environment = ["HOME": workspace.path, "CODEX_HOME": account.path, "TMPDIR": temp.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        let request: [String: Any] = ["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "noodle_storage_probe", "version": "test"],
            "capabilities": ["experimentalApi": true]]]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        // A handshake only: no sign-in, model request, or real account directory.
        let received = expectation(description: "Codex initialized")
        let reader = JSONLineReader { object in
            if object["id"] as? Int == 1, object["result"] != nil { received.fulfill() }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.receive(data) }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        wait(for: [received], timeout: 15)
    }

    func testRealProcessCanWorkAndMessageButCannotChangeConfigurationOrRuntime() throws {
        try checkBoundary(provider: .codex)
    }

    func testRestrictedFXCanWorkAndMessageWithoutAccessToOtherAccounts() throws {
        try checkBoundary(provider: .fx)
    }

    func testRestrictedGrokCanWorkAndMessageWithoutReplacingItsInstallation() throws {
        try checkBoundary(provider: .grokBuild)
    }

    func testRestrictedMuseCanWorkAndMessageWithoutAccessToOtherAccounts() throws {
        try checkBoundary(provider: .muse)
    }

    private func checkBoundary(provider: HarnessProvider) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let created = try repository.createAgent(named: "Boundary")
        let other = try repository.createAgent(named: "Private bot")
        let otherSecret = repository.directory(for: other.agent).appendingPathComponent("private.txt")
        try Data("other bot private data".utf8).write(to: otherSecret)
        let broker = MessengerBroker(repository: repository)
        try broker.start(agents: [created.agent, other.agent])
        defer { broker.stop() }
        let layout = repository.storage(for: created.agent.id)
        let state = layout.sessionState(provider: provider, extendedAccess: false)
        let original = try Data(contentsOf: layout.configuration)
        try Data("state".utf8).write(to: state)
        let home = root.appendingPathComponent("Home")
        let privateHome = RestrictedHarnessStorage.home(workspace: layout.workspace)
        let account = provider == .codex ? privateHome.appendingPathComponent(".codex")
            : try RestrictedAgentSandbox.accountDirectory(provider: provider, home: privateHome)
        let temp = layout.workspace.appendingPathComponent(".noodle/tmp")
        for directory in [account, temp] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let personal = home.appendingPathComponent("personal.txt")
        try Data("private".utf8).write(to: personal)
        let siblingAccount = home.appendingPathComponent(provider == .muse ? ".config/other" : ".other")
        try FileManager.default.createDirectory(at: siblingAccount, withIntermediateDirectories: true)
        let siblingSecret = siblingAccount.appendingPathComponent("credentials")
        try Data("other account".utf8).write(to: siblingSecret)
        if provider == .muse {
            for path in [".agents/private", ".codex/AGENTS.md", ".claude/CLAUDE.md", ".local/share/muse/session"] {
                let file = home.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("private context".utf8).write(to: file)
            }
        }
        let keychains = home.appendingPathComponent("Library/Keychains")
        try FileManager.default.createDirectory(at: keychains, withIntermediateDirectories: true)
        let loginKeychain = keychains.appendingPathComponent("login.keychain-db")
        let otherKeychain = keychains.appendingPathComponent("other.keychain-db")
        for file in [loginKeychain, otherKeychain] { try Data("keychain fixture".utf8).write(to: file) }
        let installation = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        let binary = installation.appendingPathComponent("harness")
        try Data("signed binary fixture".utf8).write(to: binary)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = project.appendingPathComponent(".build/debug/NoodleMessenger")
        let policy = provider == .codex
            ? RestrictedAgentSandbox.profile(workspace: layout.workspace, repository: repository.rootURL,
                codexHome: account, executableDirectory: installation, application: project, temporary: temp)
            : try RestrictedAgentSandbox.profile(provider: provider, workspace: layout.workspace, repository: repository.rootURL,
                home: home, executable: binary, application: project, temporary: temp)
        let script = """
        set -eu
        printf memory > "$1/allowed.txt"
        printf session > "$5/session.txt"
        printf temporary > "$TMPDIR/allowed.txt"
        /bin/zsh -fc 'cat <<EOF > "$1/heredoc.txt"
        private temporary file
        EOF' probe "$1"
        if printf changed > "$2"; then exit 11; fi
        if printf changed > "$3"; then exit 12; fi
        if rm "$2"; then exit 13; fi
        if mv "$2" "$1/stolen.json"; then exit 14; fi
        ln -s "$2" "$1/config-link"
        if printf changed > "$1/config-link"; then exit 15; fi
        if ln "$2" "$1/config-hardlink"; then
          if printf changed > "$1/config-hardlink"; then exit 18; fi
        fi
        printf replacement > "$1/replacement"
        if mv "$1/replacement" "$2"; then exit 16; fi
        if mkdir "$4/unexpected"; then exit 17; fi
        if cat "$8"; then exit 19; fi
        if printf changed > "$8"; then exit 20; fi
        if printf changed > "$9"; then exit 21; fi
        if rm "$9"; then exit 22; fi
        if mv "${9%/*}" "$1/stolen-installation"; then exit 23; fi
        if cat "${10}"; then exit 24; fi
        if printf changed > "${10}"; then exit 25; fi
        if touch "${11}/outside-workspace"; then exit 26; fi
        if [ "${14}" = 1 ]; then
          cat "${12}" > /dev/null
        elif cat "${12}" > /dev/null; then exit 27; fi
        if [ "${15}" = 1 ]; then
          # FX's no-follow skill discovery opens every directory component.
          # Listing these ancestors must not expose their other child files.
          for path in "$1" "$5"; do
            while [ "$path" != / ]; do
              ls -A "$path" > /dev/null
              path=$(dirname "$path")
            done
          done
        fi
        if printf changed > "${12}"; then exit 28; fi
        if rm "${12}"; then exit 29; fi
        if cat "${13}"; then exit 30; fi
        if cat "${17}"; then exit 35; fi
        if cat "${18}/conversation.json"; then exit 36; fi
        if printf forged > "${18}/messages.json"; then exit 37; fi
        if "$6" --agent-directory "${17%/*}" --list-conversations; then exit 38; fi
        if "$6" --agent-directory "$1" --list-messages --conversation "${19}"; then exit 39; fi
        if [ "${16}" = 1 ]; then
          for path in "${11}/.agents" "${11}/.codex" "${11}/.claude"; do
            if [ -e "$path" ]; then exit 31; fi
            if ls "$path"; then exit 32; fi
          done
          if cat "${11}/.local/share/muse/session"; then exit 33; fi
          if printf changed > "${11}/.local/share/muse/session"; then exit 34; fi
        fi
        "$6" --agent-directory "$1" --send --conversation "$7" --body 'sandbox reply'
        "$6" --agent-directory "$1" --get-latest
        """
        let process = Process(), errors = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", policy, "/bin/sh", "-c", script, "probe", layout.workspace.path,
                             layout.configuration.path, state.path, layout.package.path, account.path, helper.path,
                             created.conversation.id.uuidString, personal.path, binary.path, siblingSecret.path, home.path,
                             loginKeychain.path, otherKeychain.path, "0",
                             provider == .fx ? "1" : "0", "0", otherSecret.path,
                             repository.conversationDirectory(id: created.conversation.id).path, other.conversation.id.uuidString]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": layout.workspace.path, "TMPDIR": temp.path, "TMPPREFIX": temp.appendingPathComponent("zsh").path]
        process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, details)
        XCTAssertEqual(try Data(contentsOf: layout.configuration), original)
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), "state")
        XCTAssertEqual(try String(contentsOf: layout.workspace.appendingPathComponent("allowed.txt"), encoding: .utf8), "memory")
        XCTAssertEqual(try String(contentsOf: binary, encoding: .utf8), "signed binary fixture")
        XCTAssertEqual(try String(contentsOf: personal, encoding: .utf8), "private")
        XCTAssertEqual(try String(contentsOf: siblingSecret, encoding: .utf8), "other account")
        XCTAssertEqual(try String(contentsOf: loginKeychain, encoding: .utf8), "keychain fixture")
        XCTAssertTrue(try repository.loadMessages(conversationID: created.conversation.id).contains { $0.body == "sandbox reply" })
    }

    func testRedirectedAccountsAndUnsupportedProvidersAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home"), outside = root.appendingPathComponent("Private")
        for directory in [home, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for provider in [HarnessProvider.fx, .grokBuild, .muse] {
            let account = try RestrictedAgentSandbox.accountDirectory(provider: provider, home: home)
            try FileManager.default.createDirectory(at: account.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: account, withDestinationURL: outside)
            XCTAssertThrowsError(try RestrictedAgentSandbox.accountDirectory(provider: provider, home: home))
            XCTAssertThrowsError(try RestrictedAgentSandbox.environment(provider: provider, home: home))
        }
        for provider in [HarnessProvider.claudeCode, .apple, .codex] {
            XCTAssertThrowsError(try RestrictedAgentSandbox.accountDirectory(provider: provider, home: home))
        }
    }

    func testInstalledFXCanInitializeAndDiscoverSkillsInsideItsRestrictedProfile() throws {
        try checkInstalledACP(provider: .fx)
    }

    func testProfilesNeverGrantSharedAccountOrKeychainContent() throws {
        for provider in [HarnessProvider.fx, .grokBuild, .muse] {
            let profile = try RestrictedAgentSandbox.profile(provider: provider,
                workspace: URL(fileURLWithPath: "/fixture/bot/workspace"), repository: URL(fileURLWithPath: "/fixture"),
                home: URL(fileURLWithPath: "/private-login"), executable: URL(fileURLWithPath: "/native/harness"),
                application: URL(fileURLWithPath: "/app"), temporary: URL(fileURLWithPath: "/fixture/bot/workspace/tmp"))
            XCTAssertFalse(profile.contains("/private-login"))
            XCTAssertFalse(profile.contains("securityd.xpc"))
            XCTAssertFalse(profile.contains("login.keychain"))
        }
    }

    func testInstalledGrokCanInitializeInsideItsRestrictedProfile() throws {
        try checkInstalledACP(provider: .grokBuild)
    }

    private func checkInstalledACP(provider: HarnessProvider) throws {
        let realHome = HarnessStorage.userHome
        let installed = realHome.appendingPathComponent(provider == .fx ? ".local/bin/fx" : ".grok/bin/grok")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { throw XCTSkip("\(provider.displayName) is not installed") }
        let executable = try provider == .fx
            ? FxExecutableTrust.executable(at: installed.path, home: realHome)
            : GrokExecutableTrust.executable(at: installed.path, home: realHome)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let bot = try repository.createAgent(named: "ACP sandbox startup")
        let workspace = repository.directory(for: bot.agent), home = root.appendingPathComponent("Home")
        let temporary = workspace.appendingPathComponent("tmp")
        let account = try RestrictedAgentSandbox.accountDirectory(provider: provider, home: RestrictedHarnessStorage.home(workspace: workspace))
        for directory in [account, temporary] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let policy = try RestrictedAgentSandbox.profile(provider: provider, workspace: workspace, repository: repository.rootURL,
            home: home, executable: executable, application: workspace, temporary: temporary) + "\n(deny network*)"
        var environment = try RestrictedAgentSandbox.environment(provider: provider, home: home, workspace: workspace)
        environment["TMPDIR"] = temporary.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        let skillProbe = workspace.appendingPathComponent(".agents/skills/noodle-discovery-probe/SKILL.md")
        let skillTrace = temporary.appendingPathComponent("skill-discovery.log")
        // Satisfy FX's local presence check without real credentials, network,
        // or a model prompt. The kernel denies all network in this fixture.
        if provider == .fx {
            environment["AI_GATEWAY_API_KEY"] = "noodle-sandbox-fixture-not-a-real-key"
            environment["FX_TRACE_LOG"] = skillTrace.path
            environment["FX_TRACE_SCOPES"] = "skills"
            try FileManager.default.createDirectory(at: skillProbe.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An intentional metadata error proves FX actually read this file
            // through its no-follow directory walk during local discovery.
            try Data("---\nname: \"\"\n---\nInvalid name for the discovery test.\n".utf8).write(to: skillProbe)
        }
        let arguments = provider == .fx ? ["acp"] : ["agent", "--no-leader", "stdio"]
        let wire = try ACPWireFixture(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), workspace: workspace,
                                     arguments: ["-p", policy, executable.path] + arguments,
                                     environment: environment, requestTimeout: 15)
        defer { wire.stop() }
        let initialized = try wire.request("initialize", FxProtocol.initializeParameters)
        XCTAssertEqual(initialized["protocolVersion"] as? Int, 1)
        if provider == .fx {
            let trace = try String(contentsOf: skillTrace, encoding: .utf8)
            XCTAssertTrue(trace.split(separator: "\n").contains {
                $0.contains("kind=invalid_metadata") && $0.contains("noodle-discovery-probe")
            }, "FX did not read the workspace skill fixture. \(trace)")
        }
    }

    func testProfileQuotesPathsWithoutOpeningTheParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("quote\" (allow default) \\ folder")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let policy = RestrictedAgentSandbox.profile(workspace: workspace, repository: root,
            codexHome: workspace, executableDirectory: URL(fileURLWithPath: "/bin"), application: workspace, temporary: workspace)
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", policy, "/bin/sh", "-c", "set -e; printf ok > \"$1/ok\"; if touch \"$2/denied\"; then exit 10; fi", "probe", workspace.path, root.path]
        process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("ok"), encoding: .utf8), "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("denied").path))
    }
}
