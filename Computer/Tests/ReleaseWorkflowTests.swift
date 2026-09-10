import Foundation

// Runs publication logic against fake gh/git commands in a disposable tree.
// No GitHub connection, credentials, tags or real release assets are involved.
let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComputerRelease-Test-\(UUID().uuidString)")
let fm = FileManager.default
defer { try? fm.removeItem(at: root) }
for path in ["scripts", "Computer", "bin", "dist/computer-1.2.3"] {
    try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
}
func write(_ text: String, _ path: String) throws { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
try fm.copyItem(at: source.appendingPathComponent("scripts/publish-computer-release.sh"),
                to: root.appendingPathComponent("scripts/publish-computer-release.sh"))
try write("1.2.3\n", "Computer/VERSION")
try write("Fixture release notes\n", "notes.md")
for file in ["Noodle-Computer-1.2.3-arm64.zip", "Noodle-Computer-1.2.3-arm64.zip.sha256", "appcast.xml"] {
    try write("fixture", "dist/computer-1.2.3/" + file)
}
try write("""
#!/bin/zsh
print -r -- "$*" >> "$COMPUTER_TEST_LOG"
case "$1 $2 $3" in
    'api repos/pdparchitect/noodle --jq')
        if [[ "$COMPUTER_TEST_MODE" == private ]]; then print true; else print false; fi ;;
    'release view computer-v1.2.3') [[ "$COMPUTER_TEST_MODE" == existing ]] ;;
    'release view computer-latest')
        if [[ "$*" == *'--json assets'* ]]; then
            print -l Noodle-Computer-1.2.2-arm64.zip Noodle-Computer-1.2.2-arm64.zip.sha256 \\
                Noodle-Computer-1.2.3-arm64.zip Noodle-Computer-1.2.3-arm64.zip.sha256 appcast.xml other.txt
            exit 0
        fi
        case "$COMPUTER_TEST_MODE" in
            first) exit 1 ;;
            rollback) print 'Noodle Computer 9.0.0' ;;
            *) print 'Noodle Computer 1.2.2' ;;
        esac ;;
    'release edit computer-v1.2.3') [[ "$COMPUTER_TEST_MODE" != version-failure ]] ;;
    'release upload computer-latest')
        if [[ "$4" == *.zip && "$COMPUTER_TEST_MODE" == archive-failure ]]; then exit 1; fi
        if [[ "$4" == */appcast.xml && "$COMPUTER_TEST_MODE" == feed-failure ]]; then exit 1; fi ;;
    *) exit 0 ;;
esac
""", "bin/gh")
try write("#!/bin/zsh\nprint 0123456789012345678901234567890123456789\n", "bin/git")
for name in ["gh", "git"] { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("bin/" + name).path) }
func run(_ mode: String) throws -> (Int32, String) {
    try write("", "commands.log")
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [root.appendingPathComponent("scripts/publish-computer-release.sh").path, "1.2.3", root.appendingPathComponent("notes.md").path]
    process.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                           "COMPUTER_TEST_MODE": mode, "COMPUTER_TEST_LOG": root.appendingPathComponent("commands.log").path]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let log = try String(contentsOf: root.appendingPathComponent("commands.log"), encoding: .utf8)
    if ["first", "upgrade"].contains(mode), process.terminationStatus != 0 {
        fatalError(String(decoding: output, as: UTF8.self))
    }
    return (process.terminationStatus, log)
}
for mode in ["first", "upgrade"] {
    let (status, log) = try run(mode)
    precondition(status == 0)
    let writes = log.split(separator: "\n").filter { $0.hasPrefix("release create") || $0.hasPrefix("release edit") }
    precondition(!writes.isEmpty && writes.allSatisfy { $0.contains("--latest=false") })
    precondition(writes.first!.contains("computer-v1.2.3") && writes.first!.contains("--draft"))
    let publication = log.range(of: "release edit computer-v1.2.3")!
    let channel = log.range(of: mode == "first" ? "release create computer-latest" : "release upload computer-latest")!
    precondition(publication.lowerBound < channel.lowerBound, "Channel must follow version publication")
    let channelCommand = log.split(separator: "\n").first {
        $0.hasPrefix(mode == "first" ? "release create computer-latest" : "release upload computer-latest")
    }!
    precondition(channelCommand.contains("/Noodle-Computer-1.2.3-arm64.zip "))
    precondition(channelCommand.contains("/Noodle-Computer-1.2.3-arm64.zip.sha256 "))
    if mode == "first" {
        precondition(channelCommand.contains("/appcast.xml "))
    } else {
        let feedCommand = log.split(separator: "\n").first {
            $0.hasPrefix("release upload computer-latest ") && $0.contains("/appcast.xml ")
        }!
        let feed = log.range(of: String(feedCommand))!
        let promotion = log.range(of: "release edit computer-latest")!
        let cleanup = log.range(of: "release delete-asset computer-latest")!
        precondition(channel.lowerBound < feed.lowerBound && feed.lowerBound < promotion.lowerBound)
        precondition(promotion.lowerBound < cleanup.lowerBound)
        let deletions = log.split(separator: "\n").filter { $0.hasPrefix("release delete-asset") }
        precondition(deletions.count == 2)
        precondition(deletions.allSatisfy { $0.hasPrefix("release delete-asset computer-latest Noodle-Computer-1.2.2-arm64.zip") })
    }
    precondition(log.contains("releases/download/computer-v1.2.3/Noodle-Computer-1.2.3-arm64.zip"))
}
for mode in ["rollback", "existing", "private"] {
    let (status, log) = try run(mode)
    precondition(status != 0)
    precondition(!log.contains("release create") && !log.contains("release edit") && !log.contains("release upload"))
}
for mode in ["version-failure", "archive-failure", "feed-failure"] {
    let (status, log) = try run(mode)
    precondition(status != 0)
    precondition(!log.contains("release edit computer-latest"))
    precondition(!log.contains("release delete-asset"))
    if mode == "version-failure" { precondition(!log.contains("release upload computer-latest")) }
    if mode == "archive-failure" {
        precondition(!log.split(separator: "\n").contains {
            $0.hasPrefix("release upload computer-latest ") && $0.contains("/appcast.xml ")
        })
    }
}
print("PASS: first release and upgrade download assets, publication ordering, scoped cleanup, failure handling, Noodle latest isolation, rollback, immutable-version and private-repository guards")
