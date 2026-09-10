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
        case "$COMPUTER_TEST_MODE" in
            first) exit 1 ;;
            rollback) print 'Noodle Computer 9.0.0' ;;
            *) print 'Noodle Computer 1.2.2' ;;
        esac ;;
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
    precondition(log.contains("releases/download/computer-v1.2.3/Noodle-Computer-1.2.3-arm64.zip"))
}
for mode in ["rollback", "existing", "private"] {
    let (status, log) = try run(mode)
    precondition(status != 0)
    precondition(!log.contains("release create") && !log.contains("release edit") && !log.contains("release upload"))
}
print("PASS: first release, upgrade ordering, Noodle latest isolation, rollback, immutable-version and private-repository guards")
