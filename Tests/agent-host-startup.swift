import Foundation

// Use the same Foundation launcher as the XPC service. Launching from a shell
// alone misses the process-group-leader condition that used to break setsid().
guard CommandLine.arguments.count == 2 else { fatalError("Pass the bundled Agent Host executable") }
let process = Process()
let output = Pipe()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
process.arguments = ["--check-process-group"]
process.standardOutput = output
try process.run()
DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
    if process.isRunning { process.terminate() }
}
process.waitUntilExit()
let identifiers = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
guard process.terminationStatus == 0,
      identifiers == [process.processIdentifier, process.processIdentifier] else {
    fatalError("Agent Host must start successfully in its own process group")
}
print("Agent Host Foundation launch and isolated process group verified")
