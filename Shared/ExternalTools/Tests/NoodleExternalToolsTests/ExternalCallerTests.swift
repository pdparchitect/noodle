import Foundation
@testable import NoodleExternalTools
import Testing

private func process(_ path: String, identifier: String? = nil, team: String? = nil, cdhash: String? = nil,
                     platform: Bool = false, sandboxed: Bool = false) -> ExternalProcess {
    ExternalProcess(pid: 100, path: path, identifier: identifier, team: team, cdhash: cdhash, platform: platform, sandboxed: sandboxed)
}

@Suite struct ExternalCallerTests {
    private let zsh = process("/bin/zsh", identifier: "com.apple.zsh", platform: true)
    private let claude = process("/Users/a/.local/share/claude/versions/2.1.292", identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW")
    private let terminal = process("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", identifier: "com.apple.Terminal", platform: true)

    @Test func theCallingAppIsTheFirstThatIsNotAShell() throws {
        let launcher = try ExternalAncestry.launcher(for: [zsh, claude, terminal])
        #expect(launcher.key == "team:Q6L2SF6YDW:com.anthropic.claude-code")
        #expect(launcher.name == "Claude Code")
        #expect(launcher.path == claude.path)
    }

    @Test func runFromATerminalTheTerminalIsTheCaller() throws {
        let launcher = try ExternalAncestry.launcher(for: [zsh, process("/opt/homebrew/bin/fish"), terminal])
        #expect(launcher.name == "Terminal")
        #expect(launcher.key == "apple:com.apple.Terminal")
    }

    @Test func anUnsignedCallerIsKnownByItsCodeHashOrPath() throws {
        let node = process("/opt/homebrew/bin/node", identifier: "node", cdhash: "abc123")
        #expect(try ExternalAncestry.launcher(for: [node]).key == "cdhash:abc123")
        #expect(try ExternalAncestry.launcher(for: [node]).name == "node")
        #expect(try ExternalAncestry.launcher(for: [process("/tmp/agent")]).key == "path:/tmp/agent")
    }

    @Test func aSandboxedProcessAnywhereAboveIsRefused() {
        let sandboxed = process("/Applications/Some.app/Contents/MacOS/Some", identifier: "com.example.some", team: "ABCDE12345", sandboxed: true)
        #expect(throws: ExternalToolsError.self) { try ExternalAncestry.launcher(for: [zsh, claude, sandboxed]) }
        #expect(throws: ExternalToolsError.self) { try ExternalAncestry.launcher(for: [sandboxed]) }
    }

    @Test func noodleAndItsHubAreRefusedEvenUnsandboxed() {
        for identifier in ["com.pdparchitect.noodle", "com.pdparchitect.noodle.local.agent-host", "com.pdparchitect.noodle.hub"] {
            let noodle = process("/Applications/Noodle.app/Contents/MacOS/Noodle", identifier: identifier, team: "S8VNVK39LH")
            #expect(throws: ExternalToolsError.self) { try ExternalAncestry.launcher(for: [claude, noodle]) }
        }
    }

    @Test func nothingToIdentifyIsRefused() {
        #expect(throws: ExternalToolsError.self) { try ExternalAncestry.launcher(for: []) }
    }

    /// Terminal and SSH put root's login between the app and the shell; its parent must still be readable.
    @Test func aProcessOwnedByRootCanBeWalkedPast() throws {
        #expect(try ExternalAncestry.parent(of: 1) == 0)
        #expect(try ExternalAncestry.process(1).path == "/sbin/launchd")
    }

    /// A shell cut loose from whatever started it, as a process that wants to hide its parent does.
    @Test func aChainWithNoAppIsRefused() {
        let sh = process("/bin/sh", identifier: "com.apple.sh", platform: true)
        let login = process("/usr/bin/login", identifier: "com.apple.login", platform: true)
        #expect(throws: ExternalToolsError.self) { try ExternalAncestry.launcher(for: [sh]) }
        #expect(throws: ExternalToolsError.self) { try ExternalAncestry.launcher(for: [zsh, login]) }
    }

    /// macOS updates change Apple's programs, not who they are: Terminal stays Terminal.
    @Test func appleProgramsAreKnownByIdentifierNotCodeHash() throws {
        var updated = terminal
        updated.cdhash = "before"
        let before = try ExternalAncestry.launcher(for: [zsh, updated])
        updated.cdhash = "after"
        #expect(try ExternalAncestry.launcher(for: [zsh, updated]).key == before.key)
        #expect(before.key == "apple:com.apple.Terminal")
    }

    @Test func onlySignedOrAppleCallersAreIdentified() throws {
        #expect(try ExternalAncestry.launcher(for: [zsh, claude]).identified)
        #expect(try ExternalAncestry.launcher(for: [zsh, terminal]).identified)
        // Anyone can name a program "Claude Code"; without a developer's signature the name proves nothing.
        let impostor = process("/tmp/Claude Code", identifier: "com.anthropic.claude-code", cdhash: "ab")
        let launcher = try ExternalAncestry.launcher(for: [impostor])
        #expect(!launcher.identified)
        #expect(launcher.caution?.contains("/tmp/Claude Code") == true)
        #expect(try ExternalAncestry.launcher(for: [zsh, claude]).caution == nil)
    }

    @Test func callersThatRunAnythingAreFlagged() throws {
        let python = process("/opt/homebrew/Cellar/python@3.13/3.13.1/bin/python3.13", identifier: "python3.13", cdhash: "cd")
        let node = process("/usr/local/bin/node", identifier: "node", team: "HX7739G8FX")
        let iterm = process("/Applications/iTerm.app/Contents/MacOS/iTerm2", identifier: "com.googlecode.iterm2", team: "H7V7XYVQ7D")
        for chain in [[zsh, terminal], [python], [node], [zsh, iterm]] {
            let launcher = try ExternalAncestry.launcher(for: chain)
            #expect(launcher.broad, "\(launcher.name) runs whatever it is given")
            #expect(launcher.caution != nil)
        }
        #expect(try !ExternalAncestry.launcher(for: [zsh, claude]).broad)
    }

    /// The kernel's view of a real Apple program: part of macOS, so identified.
    @Test func aRunningAppleProgramIsReadAsPartOfMacOS() throws {
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["5"]
        try sleep.run()
        defer { sleep.terminate() }
        let read = try ExternalAncestry.process(sleep.processIdentifier)
        #expect(read.platform && !read.sandboxed && read.path == "/bin/sleep")
    }

    /// The test runner is not sandboxed and not Noodle, so the live walk names a caller.
    @Test func theLiveWalkNamesThisProcessCaller() throws {
        let launcher = try ExternalAncestry.current()
        #expect(!launcher.key.isEmpty)
        #expect(!launcher.name.isEmpty)
    }
}
