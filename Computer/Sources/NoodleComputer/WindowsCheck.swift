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
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneMultiCheck") {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let source = try ComputerStore(root: support.appendingPathComponent("Noodle Windows 3D Installation Verification"))
            guard let original = source.sessions.first(where: { $0.computer.installationComplete }) else {
                throw ComputerError("The stopped Windows installation fixture is missing.")
            }
            let target = try ComputerStore(root: support.appendingPathComponent("Noodle Windows Multiple Verification"))
            if target.sessions.isEmpty {
                for index in 1...2 {
                    var copy = original.computer
                    copy.id = UUID(); copy.name = "Windows Concurrent \(index)"
                    copy.memoryGiB = 4; copy.cpuCount = 2; copy.networkEnabled = false
                    copy.resizesDesktopWithWindow = false
                    let from = source.library.directory(for: original.id)
                    let to = target.library.stagingDirectory(for: copy.id)
                    guard clonefile(from.path, to.path, 0) == 0 else { throw ComputerError("Cloning the stopped Windows fixture failed.") }
                    try target.library.commit(copy)
                    target.sessions.append(ComputerSession(copy))
                }
            }
            withExtendedLifetime(source) {}
            return target
        }
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneReliabilityCheck") {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let source = support.appendingPathComponent("Noodle Windows Arena Verification")
            let root = support.appendingPathComponent("Noodle Windows Reliability Verification")
            // Hold the source library's exclusive lease throughout the copy: never clone a live disk.
            let stopped = try ComputerStore(root: source)
            _ = stopped
            let target = root.appendingPathComponent("Computers")
            if !FileManager.default.fileExists(atPath: target.path) {
                let staging = root.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                // APFS clones keep this independent without duplicating the disk's allocated blocks.
                guard clonefile(source.appendingPathComponent("Computers").path, staging.path, 0) == 0 else {
                    throw ComputerError("Cloning the stopped Windows fixture failed: \(String(cString: strerror(errno)))")
                }
                try FileManager.default.moveItem(at: staging, to: target)
            }
            withExtendedLifetime(stopped) {}
            return try ComputerStore(root: root)
        }
        let fresh = UserDefaults.standard.bool(forKey: "WindowsNeptuneFreshCheck")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fresh ? "Noodle Windows 3D Installation Verification" : (UserDefaults.standard.bool(forKey: "WindowsNeptuneArenaCheck") ? "Noodle Windows Arena Verification" : "Noodle Windows Verification"), isDirectory: true)
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneArenaCheck") {
            let source = root.deletingLastPathComponent().appendingPathComponent("Noodle Windows Verification/Runtime/Windows")
            let target = root.appendingPathComponent("Runtime/Windows")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            // Only clone the cached base, never the old verification computer.
            for name in ["Base.img", "Base.json"] {
                let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                    if clonefile(from.path, to.path, 0) != 0 { try FileManager.default.copyItem(at: from, to: to) }
                }
            }
        }
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
        if let kept = store.sessions.first(where: { $0.computer.kind == .windows && ($0.computer.installationComplete || UserDefaults.standard.bool(forKey: "WindowsNeptuneArenaCheck")) }) {
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
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneConsoleCheck") {
            try store.changeResources(session, cpus: 4, memoryGiB: 8, networkEnabled: session.computer.networkEnabled)
        }
        // A fixed resolution until the check turns resizing on itself.
        store.rename(session, name: session.computer.name, resizesDesktop: false)
        say("created in \(Int(Date().timeIntervalSince(started)))s")
        await store.start(session)
        guard session.phase == .running, let initialWindows = session.windows else {
            throw ComputerError("Windows did not start: \(session.phase.label)")
        }
        let windows = initialWindows
        func wait(_ what: String, minutes: Double, running: Bool = true, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(minutes * 60)
            var nextReport = Date().addingTimeInterval(30)
            var captured = false
            while !condition() {
                if UserDefaults.standard.bool(forKey: "WindowsNeptuneArenaCheck"), Date() >= nextReport {
                    say("waiting for \(what); status \(windows.status ?? "none"), screen \(windows.lastFrame.map { "\($0.width)x\($0.height)" } ?? "none")")
                    if !captured, let frame = windows.lastFrame,
                       let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) {
                        print("WINDOWS ARENA FRAME \(png.base64EncodedString())")
                        captured = true
                    }
                    nextReport = Date().addingTimeInterval(30)
                }
                guard Date() < deadline else { throw ComputerError("Timed out waiting for \(what).") }
                if case .failed(let reason) = session.phase { throw ComputerError("Windows failed while waiting for \(what): \(reason)") }
                guard !running || session.phase == .running else { throw ComputerError("Windows stopped while waiting for \(what): \(session.phase)") }
                try await Task.sleep(for: .seconds(2))
            }
        }
        try await wait("Windows to set itself up", minutes: 45) { session.computer.installationComplete && windows.agentConnected }
        say("set up and signed in after \(Int(Date().timeIntervalSince(started)))s")
        try await wait("the screen", minutes: 5) { (windows.lastFrame?.width ?? 0) >= 640 }
        say("screen \(windows.lastFrame!.width)x\(windows.lastFrame!.height)")
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneMultiCheck") {
            guard let second = store.sessions.first(where: { $0.id != session.id }) else { throw ComputerError("Second Windows fixture missing.") }
            await store.start(second)
            guard let other = second.windows else { throw ComputerError("Second Windows VM did not start: \(second.phase)") }
            try await wait("both Windows desktops", minutes: 10) { other.agentConnected && other.lastFrame != nil }
            say("both Windows VMs are signed in and rendering")
            func probe(_ vm: WindowsComputer) async throws {
                guard let source = Bundle.main.resourceURL?.appendingPathComponent("neptune-probe/Direct3DProbe.cs") else { throw ComputerError("Probe missing.") }
                let files = WindowsFileService { vm.agent }
                try await files.upload(source, to: "/C/noodle/Direct3DProbe.cs", progress: { _ in })
                let result = try await vm.agent.run(#"C:\Windows\Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe /nologo /optimize+ /out:C:\noodle\Direct3DProbe.exe C:\noodle\Direct3DProbe.cs && C:\noodle\Direct3DProbe.exe"#)
                say("concurrent Direct3D probe \(result.status):\n\(result.output)")
                guard result.status == 0 else { throw ComputerError("Concurrent Direct3D rendering failed.") }
            }
            try await probe(windows)
            try await probe(other)
            try await windows.restart()
            try await wait("first VM restart", minutes: 10) { windows.agentConnected }
            guard other.agentConnected else { throw ComputerError("Restarting the first VM disconnected the second.") }
            try await probe(windows)
            await store.stop(session)
            try await wait("first VM shutdown", minutes: 3, running: false) { session.phase == .stopped }
            try await probe(other)
            await store.stop(second)
            try await wait("second VM shutdown", minutes: 3, running: false) { second.phase == .stopped }
            say("simultaneous Windows graphics, isolated restart and shutdown passed")
            return
        }
        // Interactive diagnostics over inherited stdin, so a display experiment
        // does not need a new app build and guest boot for every command.
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneConsoleCheck") {
            say("console ready; guest commands, :frame, :quit")
            while let command = await Task.detached(operation: { readLine() }).value {
                if command == ":quit" { break }
                if command == ":frame" {
                    if let frame = windows.lastFrame, let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) {
                        print("WINDOWS ARENA FRAME \(png.base64EncodedString())")
                    }
                } else if command == ":size" {
                    say("screen \(windows.lastFrame.map { "\($0.width)x\($0.height)" } ?? "none")")
                } else {
                    let result = try await windows.agent.run(command)
                    say("result \(result.status):\n\(result.output)")
                }
            }
            await store.stop(session)
            try await wait("console shutdown", minutes: 3, running: false) { session.phase == .stopped }
            return
        }
        // Normal startup installs and verifies graphics; the check must not repair a missing driver itself.
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneFreshCheck") {
            let verified = try await windows.agent.run(WindowsNeptuneSetup.query)
            guard verified.status == 0 else { throw ComputerError("The signed 3D driver did not become active: \(verified.output)") }
            say("fresh installation uses the signed 3D driver")
        }
        if UserDefaults.standard.bool(forKey: "WindowsNeptuneReliabilityCheck") || UserDefaults.standard.bool(forKey: "WindowsNeptuneFreshCheck") {
            if UserDefaults.standard.bool(forKey: "WindowsNeptuneBenchmark"),
               let source = Bundle.main.resourceURL?.appendingPathComponent("neptune-probe/Direct3DProbe.cs") {
                let files = WindowsFileService { windows.agent }
                try await files.upload(source, to: "/C/noodle/Direct3DProbe.cs", progress: { _ in })
                let probe = try await windows.agent.run(#"C:\Windows\Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe /nologo /optimize+ /out:C:\noodle\Direct3DProbe.exe C:\noodle\Direct3DProbe.cs && C:\noodle\Direct3DProbe.exe"#)
                say("Direct3D probe (\(probe.status)):\n\(probe.output)")
                guard probe.status == 0 else { throw ComputerError("The Direct3D probe failed.") }
            }
            let cycles = UserDefaults.standard.bool(forKey: "WindowsNeptuneFreshCheck") ? 1 : 3
            for cycle in 1...cycles {
                let oldFrame = windows.lastFrame
                let before = try await windows.agent.run("powershell -NoProfile -Command \"(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc()\"")
                try await windows.restart()
                try await wait("restart \(cycle) to disconnect", minutes: 3) { !windows.agentConnected }
                try await wait("restart \(cycle) to sign in", minutes: 10) { windows.agentConnected }
                try await wait("restart \(cycle) to render a new frame", minutes: 2) { windows.lastFrame != nil && windows.lastFrame !== oldFrame }
                let after = try await windows.agent.run("powershell -NoProfile -Command \"(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc()\"")
                guard before.status == 0, after.status == 0, before.output != after.output else {
                    throw ComputerError("Windows did not report a new boot after restart \(cycle).")
                }
                say("restart \(cycle) signed in with a new boot time")
            }
            await store.stop(session)
            try await wait("shutdown", minutes: 3, running: false) { session.phase == .stopped }
            say("repeated restarts and shutdown passed")
            return
        }
        do { try await exercise(store, session, windows, say: say, wait: { what, minutes, condition in
            try await wait(what, minutes: minutes, until: condition)
        }) } catch {
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
        // Leave the existing fixture running for manual use, without executing the check's
        // driver operations, restart or shutdown. Pair with WindowsCheckReuse.
        if UserDefaults.standard.bool(forKey: "WindowsCheckInteractive") {
            if let session = store.sessions.first(where: { $0.computer.kind == .windows }) {
                store.selection = session.id
                Task { @MainActor in await store.start(session) }
            }
            return
        }
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
