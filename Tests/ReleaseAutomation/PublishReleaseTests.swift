import Foundation
import CryptoKit

// Runs each companion's publication against fake gh/git commands in a disposable tree.
// No GitHub connection, credentials, tags or real release assets are involved.
let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let fm = FileManager.default
for app in ["Computer", "Applet", "Browser", "Hub"] {
let product = app.lowercased()
let root = fm.temporaryDirectory.appendingPathComponent("\(app)Release-Test-\(UUID().uuidString)")
defer { try? fm.removeItem(at: root) }
for path in ["scripts", "\(app)/Support", "bin", "dist/\(product)-1.2.3"] {
    try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
}
func write(_ text: String, _ path: String) throws { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
for path in ["scripts/publish-xcode-release.sh", "\(app)/Support/download-page.md"] {
    try fm.copyItem(at: source.appendingPathComponent(path), to: root.appendingPathComponent(path))
}
try write("1.2.3\n", "\(app)/VERSION")
try write("Fixture release notes\n", "notes.md")
let fixtureDigest = SHA256.hash(data: Data("fixture".utf8)).map { String(format: "%02x", $0) }.joined()
for file in ["Noodle-\(app)-arm64.zip", "Noodle-\(app)-arm64.dmg", "appcast.xml"] {
    try write("fixture", "dist/\(product)-1.2.3/" + file)
    if file != "appcast.xml" {
        try write("\(fixtureDigest)  \(file)\n", "dist/\(product)-1.2.3/" + file + ".sha256")
    }
}
try write("""
#!/bin/zsh
print -r -- "$*" >> "$PUBLISH_TEST_LOG"
case "$1 $2 $3" in
    'api repos/pdparchitect/noodle --jq')
        if [[ "$PUBLISH_TEST_MODE" == private ]]; then print true; else print false; fi ;;
    'release view \(product)-v1.2.3') [[ "$PUBLISH_TEST_MODE" == existing ]] ;;
    'release view \(product)-latest')
        if [[ "$*" == *'--json assets'* ]]; then
            print -l Noodle-\(app)-arm64.zip Noodle-\(app)-arm64.zip.sha256 appcast.xml other.txt
            exit 0
        fi
        case "$PUBLISH_TEST_MODE" in
            first) exit 1 ;;
            rollback) print 'Noodle \(app) 9.0.0' ;;
            *) print 'Noodle \(app) 1.2.2' ;;
        esac ;;
    'release edit \(product)-v1.2.3') [[ "$PUBLISH_TEST_MODE" != version-failure ]] ;;
    'release upload \(product)-latest')
        # Fixed-name assets already exist on established channels.
        if [[ "$PUBLISH_TEST_MODE" == upgrade && "$*" != *'--clobber'* ]]; then exit 1; fi
        if [[ "$4" == *.zip && "$PUBLISH_TEST_MODE" == archive-failure ]]; then exit 1; fi
        if [[ "$5" == *.zip.sha256 && "$PUBLISH_TEST_MODE" == checksum-failure ]]; then exit 1; fi
        if [[ "$6" == *.dmg && "$PUBLISH_TEST_MODE" == dmg-failure ]]; then exit 1; fi
        if [[ "$7" == *.dmg.sha256 && "$PUBLISH_TEST_MODE" == dmg-checksum-failure ]]; then exit 1; fi
        if [[ "$4" == */appcast.xml && "$PUBLISH_TEST_MODE" == feed-failure ]]; then exit 1; fi ;;
    *) exit 0 ;;
esac
""", "bin/gh")
try write("#!/bin/zsh\nprint 0123456789012345678901234567890123456789\n", "bin/git")
for name in ["gh", "git"] { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("bin/" + name).path) }
func run(_ mode: String) throws -> (Int32, String) {
    try write("", "commands.log")
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [root.appendingPathComponent("scripts/publish-xcode-release.sh").path, app, "1.2.3", root.appendingPathComponent("notes.md").path]
    process.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                           "PUBLISH_TEST_MODE": mode, "PUBLISH_TEST_LOG": root.appendingPathComponent("commands.log").path]
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
    precondition(writes.first!.contains("\(product)-v1.2.3") && writes.first!.contains("--draft"))
    precondition(!writes.first!.contains("--clobber"))
    precondition(writes.first!.contains("/Noodle-\(app)-arm64.zip "))
    precondition(writes.first!.contains("/Noodle-\(app)-arm64.dmg "))
    precondition(writes.first!.contains("/Noodle-\(app)-arm64.dmg.sha256 "))
    let publication = log.range(of: "release edit \(product)-v1.2.3")!
    let channel = log.range(of: mode == "first" ? "release create \(product)-latest" : "release upload \(product)-latest")!
    precondition(publication.lowerBound < channel.lowerBound, "Channel must follow version publication")
    let channelCommand = log.split(separator: "\n").first {
        $0.hasPrefix(mode == "first" ? "release create \(product)-latest" : "release upload \(product)-latest")
    }!
    precondition(channelCommand.contains("/Noodle-\(app)-arm64.zip "))
    precondition(channelCommand.contains("/Noodle-\(app)-arm64.zip.sha256 "))
    precondition(channelCommand.contains("/Noodle-\(app)-arm64.dmg "))
    precondition(channelCommand.contains("/Noodle-\(app)-arm64.dmg.sha256 "))
    if mode == "first" {
        precondition(channelCommand.contains("/appcast.xml "))
    } else {
        precondition(channelCommand.contains("--clobber"))
        let feedCommand = log.split(separator: "\n").first {
            $0.hasPrefix("release upload \(product)-latest ") && $0.contains("/appcast.xml ")
        }!
        let feed = log.range(of: String(feedCommand))!
        let promotion = log.range(of: "release edit \(product)-latest")!
        precondition(channel.lowerBound < feed.lowerBound && feed.lowerBound < promotion.lowerBound)
        precondition(feedCommand.contains("--clobber"))
    }
    precondition(!log.contains("release delete-asset"), "Publication never deletes a channel's downloads")
    // The channel page is the app's own, filled in for this release.
    precondition(log.contains("--notes Noodle \(app) 1.2.3") && log.contains("Requires macOS"))
    precondition(log.contains("releases/download/\(product)-v1.2.3/Noodle-\(app)-arm64.zip"))
}
for mode in ["rollback", "existing", "private"] {
    let (status, log) = try run(mode)
    precondition(status != 0)
    precondition(!log.contains("release create") && !log.contains("release edit") && !log.contains("release upload"))
}
for mode in ["version-failure", "archive-failure", "checksum-failure", "dmg-failure", "dmg-checksum-failure", "feed-failure"] {
    let (status, log) = try run(mode)
    precondition(status != 0)
    precondition(!log.contains("release edit \(product)-latest"))
    precondition(!log.contains("release delete-asset"))
    if mode == "version-failure" { precondition(!log.contains("release upload \(product)-latest")) }
    if ["archive-failure", "checksum-failure", "dmg-failure", "dmg-checksum-failure"].contains(mode) {
        precondition(!log.split(separator: "\n").contains {
            $0.hasPrefix("release upload \(product)-latest ") && $0.contains("/appcast.xml ")
        })
    }
}
print("PASS \(app): first release and upgrade download assets, publication ordering, failure handling, Noodle latest isolation, rollback, immutable-version and private-repository guards")
}
