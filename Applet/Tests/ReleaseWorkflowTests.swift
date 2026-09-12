import Foundation

// Runs publication logic against fake gh/git commands in a disposable tree.
// No GitHub connection, credentials, tags or real release assets are involved.
let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppletRelease-Test-\(UUID().uuidString)")
let fm = FileManager.default
defer { try? fm.removeItem(at: root) }
for path in ["scripts", "Applet", "bin", "dist/applet-1.2.3"] {
    try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
}
func write(_ text: String, _ path: String) throws { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
try fm.copyItem(at: source.appendingPathComponent("scripts/publish-applet-release.sh"),
                to: root.appendingPathComponent("scripts/publish-applet-release.sh"))
try write("1.2.3\n", "Applet/VERSION")
try write("Fixture release notes\n", "notes.md")
for file in ["Noodle-Applet-1.2.3-arm64.zip", "Noodle-Applet-1.2.3-arm64.zip.sha256", "appcast.xml"] {
    try write("fixture", "dist/applet-1.2.3/" + file)
}
try write("""
#!/bin/zsh
print -r -- "$*" >> "$APPLET_TEST_LOG"
case "$1 $2 $3" in
    'api repos/pdparchitect/noodle --jq')
        if [[ "$APPLET_TEST_MODE" == private ]]; then print true; else print false; fi ;;
    'release view applet-v1.2.3') [[ "$APPLET_TEST_MODE" == existing ]] ;;
    'release view applet-latest')
        if [[ "$*" == *'--json assets'* ]]; then
            print -l Noodle-Applet-1.2.2-arm64.zip Noodle-Applet-1.2.2-arm64.zip.sha256 \\
                Noodle-Applet-1.2.3-arm64.zip Noodle-Applet-1.2.3-arm64.zip.sha256 appcast.xml other.txt
            exit 0
        fi
        case "$APPLET_TEST_MODE" in
            first) exit 1 ;;
            rollback) print 'Noodle Applet 9.0.0' ;;
            *) print 'Noodle Applet 1.2.2' ;;
        esac ;;
    'release edit applet-v1.2.3') [[ "$APPLET_TEST_MODE" != version-failure ]] ;;
    'release upload applet-latest')
        if [[ "$4" == *.zip && "$APPLET_TEST_MODE" == archive-failure ]]; then exit 1; fi
        if [[ "$4" == */appcast.xml && "$APPLET_TEST_MODE" == feed-failure ]]; then exit 1; fi ;;
    *) exit 0 ;;
esac
""", "bin/gh")
try write("#!/bin/zsh\nprint 0123456789012345678901234567890123456789\n", "bin/git")
for name in ["gh", "git"] { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("bin/" + name).path) }
func run(_ mode: String) throws -> (Int32, String) {
    try write("", "commands.log")
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [root.appendingPathComponent("scripts/publish-applet-release.sh").path, "1.2.3", root.appendingPathComponent("notes.md").path]
    process.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                           "APPLET_TEST_MODE": mode, "APPLET_TEST_LOG": root.appendingPathComponent("commands.log").path]
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
    precondition(writes.first!.contains("applet-v1.2.3") && writes.first!.contains("--draft"))
    let publication = log.range(of: "release edit applet-v1.2.3")!
    let channel = log.range(of: mode == "first" ? "release create applet-latest" : "release upload applet-latest")!
    precondition(publication.lowerBound < channel.lowerBound, "Channel must follow version publication")
    let channelCommand = log.split(separator: "\n").first {
        $0.hasPrefix(mode == "first" ? "release create applet-latest" : "release upload applet-latest")
    }!
    precondition(channelCommand.contains("/Noodle-Applet-1.2.3-arm64.zip "))
    precondition(channelCommand.contains("/Noodle-Applet-1.2.3-arm64.zip.sha256 "))
    if mode == "first" {
        precondition(channelCommand.contains("/appcast.xml "))
    } else {
        let feedCommand = log.split(separator: "\n").first {
            $0.hasPrefix("release upload applet-latest ") && $0.contains("/appcast.xml ")
        }!
        let feed = log.range(of: String(feedCommand))!
        let promotion = log.range(of: "release edit applet-latest")!
        let cleanup = log.range(of: "release delete-asset applet-latest")!
        precondition(channel.lowerBound < feed.lowerBound && feed.lowerBound < promotion.lowerBound)
        precondition(promotion.lowerBound < cleanup.lowerBound)
        let deletions = log.split(separator: "\n").filter { $0.hasPrefix("release delete-asset") }
        precondition(deletions.count == 2)
        precondition(deletions.allSatisfy { $0.hasPrefix("release delete-asset applet-latest Noodle-Applet-1.2.2-arm64.zip") })
    }
    precondition(log.contains("releases/download/applet-v1.2.3/Noodle-Applet-1.2.3-arm64.zip"))
}
for mode in ["rollback", "existing", "private"] {
    let (status, log) = try run(mode)
    precondition(status != 0)
    precondition(!log.contains("release create") && !log.contains("release edit") && !log.contains("release upload"))
}
for mode in ["version-failure", "archive-failure", "feed-failure"] {
    let (status, log) = try run(mode)
    precondition(status != 0)
    precondition(!log.contains("release edit applet-latest"))
    precondition(!log.contains("release delete-asset"))
    if mode == "version-failure" { precondition(!log.contains("release upload applet-latest")) }
    if mode == "archive-failure" {
        precondition(!log.split(separator: "\n").contains {
            $0.hasPrefix("release upload applet-latest ") && $0.contains("/appcast.xml ")
        })
    }
}
print("PASS: first release and upgrade download assets, publication ordering, scoped cleanup, failure handling, Noodle latest isolation, rollback, immutable-version and private-repository guards")
