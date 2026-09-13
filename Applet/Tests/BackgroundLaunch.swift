import AppKit

/// Compile with AppletLaunch.swift and run inside a signed app-sandbox bundle.
/// The target Applet must be stopped first; the shell runner cleans up its launch.
@main struct BackgroundLaunchTest {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        do {
            try await run()
        } catch {
            fputs("BACKGROUND LAUNCH FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "BackgroundLaunchTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let id = CommandLine.arguments[1]
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            throw CocoaError(.fileNoSuchFile)
        }
        print("Target: \(url.path)")
        try require(url.standardizedFileURL == URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL,
            "Launch Services resolved a different Applet build.")
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
            "Quit the target Applet before testing; no existing instance will be interrupted.")
        func visibleWindows(_ app: NSRunningApplication) throws -> Int {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else { throw CocoaError(.featureUnsupported) }
            return windows.filter {
                ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }.count
        }

        let app: NSRunningApplication
        if CommandLine.arguments.contains("--legacy") {
            // Reproduce the original failure: the sandbox drops the background argument,
            // and the open-application event still takes the normal app-launch path.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["--noodle-background"]
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(keyAELaunchedAsServiceItem))
            configuration.appleEvent = event
            app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else {
            app = try await AppletLaunch.openInBackground(at: url)
        }
        print("Launched test Applet PID \(app.processIdentifier)")
        try await Task.sleep(for: .seconds(2))
        try require(try visibleWindows(app) == 0 && !app.isActive,
            "A sandboxed background cold launch displayed a window or activated Applet.")
        print("PASS: sandboxed cold launch has no visible windows or activation")
        for _ in 0..<3 {
            let reused = try await AppletLaunch.openInBackground(at: url)
            try require(reused.processIdentifier == app.processIdentifier, "Background launch created another process.")
        }
        try await Task.sleep(for: .seconds(1))
        try require(try visibleWindows(app) == 0 && !app.isActive,
            "Repeated sandboxed background requests displayed a window or activated Applet.")
        print("PASS: repeated sandboxed background requests keep the catalogue closed")

        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        try await Task.sleep(for: .seconds(2))
        try require(try visibleWindows(app) > 0,
            "Explicit open did not show the library, or window observation is unavailable.")
        print("PASS: explicit open shows the library; cross-process window observation is working")
    }
}
