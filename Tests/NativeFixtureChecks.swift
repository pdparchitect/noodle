import AppKit

/// A failed UI check is a test result, not an application crash. Exit normally
/// so a failed run cannot leave macOS crash-report dialogs on the user's desktop.
@MainActor func fixtureFailure(_ message: String, file: String = #fileID, line: UInt = #line) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(file):\(line): \(message)\n".utf8))
    NSApp?.windows.forEach { $0.orderOut(nil) }
    exit(1)
}

@MainActor func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Check failed",
                        file: String = #fileID, line: UInt = #line) {
    if !condition() { fixtureFailure(message(), file: file, line: line) }
}
