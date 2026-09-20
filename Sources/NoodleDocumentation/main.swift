import Foundation
import NoodleCore
import AppletBridge

// Build utility only; never bundled into the application or run by a bot. It writes the
// Applet CLI's help text, which ships as a resource because the CLI is a separate package.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, ["--write-applet-help", "--write-applet-dev-help"].contains(arguments[0]) else {
    FileHandle.standardError.write(Data("Usage: NoodleDocumentation --write-applet-help|--write-applet-dev-help <file>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
do {
    try MessengerDocumentation.appletCLIHelp(for: arguments[0] == "--write-applet-dev-help" ? .development : .production)
        .write(to: url, atomically: true, encoding: .utf8)
    FileHandle.standardError.write(Data("Generated \(url.path)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Applet help: \(error.localizedDescription)\n".utf8))
    exit(1)
}
