#if NOODLE_DEV_HOOKS
import AppKit
import ComputerCore
import Foundation
import os

/// `--windows-test`: makes a Windows computer in a library of its own, which keeps its base image between runs,
/// shows it in the library window, and checks it end to end: setup, screen, commands, a PowerShell console,
/// files both ways, a restart and a shutdown. Prints "WINDOWS CHECK PASSED" or "WINDOWS CHECK FAILED".
@available(macOS 27, *)
@MainActor enum WindowsCheck {
    static func fixture() throws -> ComputerStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noodle Windows Verification", isDirectory: true)
        let store = try ComputerStore(root: root)
        // A fresh computer every run, unless `-WindowsCheckReuse YES` asks to keep the last one; the base image
        // under Runtime is kept either way.
        if !UserDefaults.standard.bool(forKey: "WindowsCheckReuse") {
            for session in store.sessions { store.remove(session) }
        }
        return store
    }

    static func run(_ store: ComputerStore) async throws {
        setbuf(stdout, nil)
        let log = Logger(subsystem: "com.pdparchitect.noodle.computer", category: "WindowsCheck")
        func say(_ text: String) { print("WINDOWS: \(text)"); log.info("\(text, privacy: .public)") }
        let started = Date()
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                if let status = store.creationStatus {
                    say("\(status) \(store.creationProgress.map { String(format: "%.0f%%", $0 * 100) } ?? "") \(store.creationDetail ?? "")")
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        defer { monitor.cancel() }
        let session: ComputerSession
        if let kept = store.sessions.first(where: { $0.computer.kind == .windows && $0.computer.installationComplete }) {
            session = kept
            say("reusing \(kept.computer.name)")
        } else {
            let computer = Computer(name: "Windows Check", kind: .windows, cpuCount: min(4, ProcessInfo.processInfo.processorCount),
                                    memoryGiB: 8, diskGiB: 64)
            guard await store.create(computer, source: nil), let made = store.sessions.first(where: { $0.id == computer.id }) else {
                throw ComputerError(store.error ?? "Creating the Windows computer failed.")
            }
            session = made
        }
        store.selection = session.id
        // A fixed resolution until the check turns resizing on itself.
        store.rename(session, name: session.computer.name, resizesDesktop: false)
        say("created in \(Int(Date().timeIntervalSince(started)))s")
        await store.start(session)
        guard session.phase == .running, let windows = session.windows else {
            throw ComputerError("Windows did not start: \(session.phase.label)")
        }

        func wait(_ what: String, minutes: Double, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(minutes * 60)
            while !condition() {
                guard Date() < deadline else { throw ComputerError("Timed out waiting for \(what).") }
                guard session.phase == .running else { throw ComputerError("Windows stopped while waiting for \(what): \(session.phase.label)") }
                try await Task.sleep(for: .seconds(2))
            }
        }
        try await wait("Windows to set itself up", minutes: 45) { session.computer.installationComplete && windows.agentConnected }
        say("set up and signed in after \(Int(Date().timeIntervalSince(started)))s")
        try await wait("the screen", minutes: 5) { (windows.lastFrame?.width ?? 0) >= 640 }
        say("screen \(windows.lastFrame!.width)x\(windows.lastFrame!.height)")
        // The screen follows the window: the size the view reports, and back to 1920 by 1080 when it stops.
        for (width, height) in [(1280, 800), (1600, 1000)] {
            windows.showScreen(at: CGSize(width: width, height: height))
            try await wait("Windows to take \(width)x\(height)", minutes: 1) {
                windows.lastFrame?.width == width && windows.lastFrame?.height == height
            }
            say("resized to \(width)x\(height)")
        }
        windows.showScreen(at: nil)
        try await wait("Windows to return to 1920x1080", minutes: 1) { windows.lastFrame?.width == 1920 && windows.lastFrame?.height == 1080 }
        say("screen back to 1920x1080")
        // Through the window: with the setting on, Windows takes the library view's size.
        store.rename(session, name: session.computer.name, resizesDesktop: true)
        try await wait("Windows to follow its window", minutes: 1) {
            windows.lastFrame.map { $0.width != 1920 || $0.height != 1080 } ?? false
        }
        say("follows its window at \(windows.lastFrame!.width)x\(windows.lastFrame!.height)")
        store.rename(session, name: session.computer.name, resizesDesktop: false)
        try await wait("Windows to keep 1920x1080 again", minutes: 1) { windows.lastFrame?.width == 1920 && windows.lastFrame?.height == 1080 }

        do { try await exercise(store, session, windows, say: say, wait: wait) } catch {
            // The agent's own log says why it went away, once it is back.
            for _ in 0..<90 where !windows.agentConnected { try? await Task.sleep(for: .seconds(2)) }
            if windows.agentConnected, let log = try? await windows.agent.run("type C:\\noodle\\agent.log") {
                say("agent log:\n\(log.output.suffix(4000))")
            }
            // Leave Windows shut down properly, not cut off when the check ends.
            await store.stop(session)
            for _ in 0..<120 where session.phase != .stopped { try? await Task.sleep(for: .seconds(1)) }
            throw error
        }
        await store.stop(session)
        let deadline = Date().addingTimeInterval(180)
        while session.phase != .stopped {
            guard Date() < deadline else { throw ComputerError("Windows did not shut down: \(session.phase.label)") }
            try await Task.sleep(for: .seconds(1))
        }
        say("shut down after \(Int(Date().timeIntervalSince(started)))s in all")
    }

    private static func exercise(_ store: ComputerStore, _ session: ComputerSession, _ windows: WindowsComputer,
                                 say: (String) -> Void, wait: (String, Double, () -> Bool) async throws -> Void) async throws {
        let version = try await windows.agent.run("ver")
        guard version.status == 0, version.output.contains("Windows") else { throw ComputerError("ver failed: \(version)") }
        say("command: \(version.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        let history = try await windows.agent.run("powershell -NoProfile -Command \"Get-Content C:\\noodle\\agent.log -Tail 40\"")
        say("agent log so far:\n\(history.output)")
        var network = (output: "", status: Int32(-1))
        for _ in 0..<12 {
            network = try await windows.agent.run("curl.exe -sS -o NUL -w \"%{http_code}\" https://www.microsoft.com/")
            if network.output.hasPrefix("200") || network.output.hasPrefix("30") { break }
            try await Task.sleep(for: .seconds(5))
        }
        say("network: \(network.output.hasPrefix("200") || network.output.hasPrefix("30") ? "online" : "offline (\(network.output.prefix(200)))")")

        // The console, through ConPTY.
        let console = Captured()
        let channel = windows.agent.open { frame in if frame.type == 101 { console.append(frame.payload) } }
        windows.agent.send(1, channel: channel, payload: try JSONSerialization.data(withJSONObject: ["cmd": "powershell.exe -NoLogo", "pty": true, "cols": 100, "rows": 30]))
        let opened = Date()
        windows.agent.send(2, channel: channel, payload: Data("Write-Output (\"noodle-\" + \"console-ok\")\r".utf8))
        try await wait("the console", 4) { console.text.contains("noodle-console-ok") }
        say("console answered after \(Int(Date().timeIntervalSince(opened)))s")
        windows.agent.send(5, channel: channel)
        windows.agent.close(channel)
        say("console works")

        // Files, both ways, through the same service the Files view uses.
        let files = WindowsFileService { windows.agent }
        let home = try await files.homeDirectory()
        guard try await files.list("/").contains(where: { $0.name == "C" }) else { throw ComputerError("The C drive is not listed.") }
        let folder = home + "/Noodle Check"
        try? await files.change("remove", path: folder, extra: [])
        try await files.change("mkdir", path: folder, extra: [])
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-windows-check-\(UUID().uuidString)")
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try payload.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try await files.upload(local, to: folder + "/sent.bin", progress: { _ in })
        try await files.change("rename", path: folder + "/sent.bin", extra: [folder + "/kept.bin"])
        let back = local.appendingPathExtension("back")
        defer { try? FileManager.default.removeItem(at: back) }
        _ = try await files.download(folder + "/kept.bin", to: back)
        guard try Data(contentsOf: back) == payload else { throw ComputerError("The file came back different.") }
        guard try await files.list(folder).map(\.name) == ["kept.bin"] else { throw ComputerError("The folder listing is wrong.") }
        try await files.change("remove", path: folder, extra: [])
        say("files work both ways")

        // A restart inside Windows comes back as a power cycle.
        try await windows.restart()
        try await wait("Windows to go down for the restart", 3) { !windows.agentConnected }
        try await wait("Windows to come back after the restart", 10) { windows.agentConnected }
        say("restart works")
    }

    /// Runs the check, says how it went and ends the process unless the window is kept.
    static func start(_ store: ComputerStore) {
        Task { @MainActor in
            do {
                try await run(store)
                print("WINDOWS CHECK PASSED")
                Logger(subsystem: "com.pdparchitect.noodle.computer", category: "WindowsCheck").info("WINDOWS CHECK PASSED")
                if !ComputerLaunchCheck.keepsTestWindow { exit(0) }
            } catch {
                print("WINDOWS CHECK FAILED: \(error.localizedDescription)")
                Logger(subsystem: "com.pdparchitect.noodle.computer", category: "WindowsCheck")
                    .error("WINDOWS CHECK FAILED: \(error.localizedDescription, privacy: .public)")
                if !ComputerLaunchCheck.keepsTestWindow { exit(1) }
            }
        }
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
#endif
