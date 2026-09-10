import Foundation

/// Run from the repository root with `swift Computer/Tests/TerminalPromptTests.swift`.
/// Exercise the actual configured prompt with sh, dash and Bash, without a guest.
let source = try String(contentsOfFile: "Computer/Sources/NoodleComputer/ContainerComputer.swift", encoding: .utf8)
let prompt = source.components(separatedBy: "\"PS1=")[1].components(separatedBy: "\"")[0]
// Keep the path short so interactive line editors do not truncate the prompt.
let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("np-" + UUID().uuidString.prefix(8))
try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder with spaces"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let path = directory.resolvingSymlinksInPath().path

for shell in ["/bin/sh", "/bin/dash", "/bin/bash"] {
    let process = Process()
    let input = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-i"]
    process.currentDirectoryURL = directory
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": path, "TERM": "dumb", "PS1": prompt]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data("cd 'folder with spaces'\ncd ..\nexit\n".utf8))
    try input.fileHandleForWriting.close()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0, !text.contains(#"\w"#),
          text.contains(path + "/folder with spaces # "),
          text.components(separatedBy: path + " # ").count >= 3 else {
        fputs("FAIL: \(shell) prompt: \(text)\n", stderr)
        exit(1)
    }
    print("PASS: \(shell) shows the current directory and updates after cd, including spaces")
}
