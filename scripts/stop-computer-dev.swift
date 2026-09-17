import AppKit

// The installer must stop the old process before unlinking its signed image.
// Scope by the exact development identity, never by process or display name.
guard CommandLine.arguments.count == 1 else { exit(1) }
let identifiers = ["com.pdparchitect.noodle.computer.local", "com.pdparchitect.noodle.computer.local.localmacsetup"]
let applications = identifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
for application in applications where !application.isTerminated {
    guard application.terminate() else {
        fputs("Computer Dev could not quit. Close it before installing the update.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(20)
while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard identifiers.flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0) }).allSatisfy({ $0.isTerminated }) else {
    fputs("Computer Dev is still running. Its installed app was not replaced.\n", stderr)
    exit(1)
}
