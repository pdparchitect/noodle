import Foundation
import NoodleCore

// Development utility only; never bundled into the application or run by a bot.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, ["--write", "--check", "--write-applet-help"].contains(arguments[0]) else {
    FileHandle.standardError.write(Data("Usage: NoodleDocumentation --write|--check <reference.md>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let expected = arguments[0] == "--write-applet-help" ? MessengerDocumentation.appletCLIHelp : MessengerDocumentation.referenceMarkdown
do {
    if arguments[0] == "--write" || arguments[0] == "--write-applet-help" {
        try expected.write(to: url, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("Generated \(url.path)\n".utf8))
    } else {
        guard try String(contentsOf: url, encoding: .utf8) == expected else {
            FileHandle.standardError.write(Data("Message reference is out of date. Run: swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md\n".utf8))
            exit(1)
        }
        print("Message reference is current.")
    }
} catch {
    FileHandle.standardError.write(Data("Message reference: \(error.localizedDescription)\nRun: swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md\n".utf8))
    exit(1)
}
