import XCTest
@testable import NoodleAppleRuntime

final class AppleCommandPathTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var path: String { workspace.path }
    private var escaped: String { path.replacingOccurrences(of: " ", with: "\\ ") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("apple path \(UUID())").resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("Application Support/work space", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/tmp"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func keeping(_ command: String) -> String {
        AppleCommand.keepingPathsWhole(command, paths: [path])
    }

    func testUnquotedWorkspacePathStaysOneArgument() async throws {
        try "hello".write(to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        for command in ["cd \(path) && pwd",
                        "mkdir -p \(path)/made && test -d \(path)/made",
                        "find \(path) -maxdepth 0",
                        "cat \(path)/notes.txt",
                        "ls -d \(path)/made 2>/dev/null; cd \(path); test \"$PWD\" = \"\(path)\"",
                        "FOLDER=\(path) && test -d \"$FOLDER\""] {
            let result = try await AppleCommand.run(command, workspace: workspace)
            XCTAssertEqual(result.status, 0, "\(command)\n\(result.output)")
        }
        let find = try await AppleCommand.run("find \(path) -maxdepth 0", workspace: workspace)
        XCTAssertEqual(find.output.trimmingCharacters(in: .whitespacesAndNewlines), path)
    }

    func testQuotedAndEscapedPathsRunAsWritten() async throws {
        for command in ["cd '\(path)' && pwd", "cd \"\(path)\" && pwd", "cd \(escaped) && pwd", "cd $'\(path)' && pwd"] {
            XCTAssertEqual(keeping(command), command)
            let result = try await AppleCommand.run(command, workspace: workspace)
            XCTAssertEqual(result.status, 0, "\(command)\n\(result.output)")
        }
    }

    func testRewriteEscapesOnlyTheUnquotedCopy() {
        XCTAssertEqual(keeping("cd \(path) && ls"), "cd \(escaped) && ls")
        XCTAssertEqual(keeping("ls \(path)/a; ls '\(path)/b'"), "ls \(escaped)/a; ls '\(path)/b'")
        XCTAssertEqual(keeping("echo \"\(path)\" \(path)"), "echo \"\(path)\" \(escaped)")
        XCTAssertEqual(keeping("X=\(path) true"), "X=\(escaped) true")
    }

    func testCommentsHereDocumentsAndOtherWordsAreLeftAlone() {
        for command in ["true # cd \(path)",
                        "cat <<EOF\n\(path)\nEOF",
                        "ls /tmp/other dir",
                        "ls x\(path)",
                        "echo \"unterminated \(path)"] {
            XCTAssertEqual(keeping(command), command)
        }
    }

    func testLongerWordThatOnlyBeginsWithThePathIsLeftAlone() async throws {
        for command in ["ls \(path)ing", "ls \(path)-old", "ls \(path).bak", "cd \(path)2 && pwd", "echo \(path)x\(path)y"] {
            XCTAssertEqual(keeping(command), command)
        }
        // The path itself, at the end of the command, before a slash or before a separator, is still one word.
        XCTAssertEqual(keeping("ls \(path)"), "ls \(escaped)")
        XCTAssertEqual(keeping("ls \(path)/sub"), "ls \(escaped)/sub")
        XCTAssertEqual(keeping("ls \(path);ls \(path)|cat \(path)>out \(path)<in"), "ls \(escaped);ls \(escaped)|cat \(escaped)>out \(escaped)<in")
        XCTAssertEqual(keeping("(cd \(path))"), "(cd \(escaped))")
        XCTAssertEqual(keeping("ls \(path)\ntrue"), "ls \(escaped)\ntrue")
        let sibling = workspace.deletingLastPathComponent().appendingPathComponent("work spacing")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let result = try await AppleCommand.run("ls -d \(path)ing", workspace: workspace)
        XCTAssertNotEqual(result.status, 0, "A longer name must not be read as the workspace path: \(result.output)")
    }

    func testPathWithoutASpaceIsNotRewritten() {
        let command = "cd /tmp/plain && ls"
        XCTAssertEqual(AppleCommand.keepingPathsWhole(command, paths: ["/tmp/plain"]), command)
    }

    func testPathWithAControlCharacterIsNotRewritten() {
        let command = "cd /tmp/a b\nc"
        XCTAssertEqual(AppleCommand.keepingPathsWhole(command, paths: ["/tmp/a b\nc"]), command)
    }
}
