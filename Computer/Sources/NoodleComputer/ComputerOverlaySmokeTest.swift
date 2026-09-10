import AppKit
import ComputerCore
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import CryptoKit
import Foundation

/// Uses a disposable library and two controlled versions of a tiny Alpine image.
/// No user computers, external image tags or registry assets are modified.
@MainActor enum ComputerOverlaySmokeTest {
    static func checkLatestTemplates() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleLatest-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                print("LATEST: \(store.creationStatus ?? "verifying") \(store.creationDetail ?? "")")
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { monitor.cancel() }
        do {
            let missing = "ghcr.io/pdparchitect/noodle-computer-shell-image:missing-\(UUID().uuidString.lowercased())"
            let images = try ImageStore(path: store.cache.appendingPathComponent("Images"))
            do {
                _ = try await ContainerComputer.registryRequest(reference: missing) {
                    try await images.pull(reference: missing, platform: .current)
                }
                throw ComputerError("A nonexistent image unexpectedly resolved")
            } catch {
                guard error.localizedDescription.contains(missing), error.localizedDescription.contains("HTTP 404") else { throw error }
                print("PASS: missing tag produces an actionable error")
            }
            for template in [ComputerTemplate.shell, .desktop] {
                let computer = template.makeComputer(name: "Latest \(template.defaultName) verification")
                guard computer.imageReference.hasSuffix(":latest"),
                      await store.create(computer, source: nil), let session = store.selected else {
                    throw ComputerError(store.error ?? "Latest template creation failed")
                }
                if session.phase != .running { await store.start(session) }
                guard session.phase == .running, let runtime = session.container else {
                    throw ComputerError("Latest \(template.defaultName) startup failed: \(session.console)")
                }
                try await check(runtime, ContainerComputer.overlayCheckCommand)
                try await check(runtime, "test -s /etc/resolv.conf; echo latest-check > /workspace/latest-check")
                if template == .desktop {
                    try await check(runtime, "for attempt in 1 2 3 4 5 6 7 8 9 10; do if pgrep -x Xvnc && pgrep -x openbox; then exit 0; fi; sleep 1; done; exit 1")
                    guard session.desktop != nil else { throw ComputerError("Latest Desktop has no display connection") }
                }
                await store.stop(session)
                await store.updateImage(session)
                guard store.error == nil, session.phase == .stopped else {
                    throw ComputerError(store.error ?? "Latest image update failed")
                }
                print("PASS: latest \(template.defaultName) fresh creation, overlay startup, writes and update check")
            }
            await store.shutdown()
            try FileManager.default.removeItem(at: root)
        } catch {
            await store.shutdown()
            print("Latest fixture retained for diagnosis: \(root.path)")
            throw error
        }
    }

    static func run() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleOverlay-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        let computer = Computer(name: "Overlay fixture", kind: .container, cpuCount: 2, memoryGiB: 1,
                                diskGiB: 4, networkEnabled: false,
                                imageReference: "docker.io/library/alpine:3.23.5", customImage: true)
        guard await store.create(computer, source: nil), let session = store.selected else {
            throw ComputerError(store.error ?? "Overlay fixture creation failed")
        }
        if session.phase == .running { await store.stop(session) }
        let directory = store.library.directory(for: session.id)
        let original = try ContainerDiskState.load(in: directory)
        let layers = original.directory(in: directory)
        print("OVERLAY FIXTURE: \(root.path)")
        let runtime = ContainerComputer()
        do {
            try await seedBase(layers.appendingPathComponent("Base.ext4"), value: "old", store: store)
            let baseHash = try hash(layers.appendingPathComponent("Base.ext4"))
            _ = try await runtime.start(computer: computer, directory: directory, cache: store.cache, kernel: store.kernel)
            print(try await runtime.execute("stat -f -c %T /; cat /proc/mounts"))
            try await check(runtime, ContainerComputer.overlayCheckCommand)
            try await check(runtime, "echo user-data > /workspace/keep; echo user-edit > /etc/overlay-user; rm /etc/overlay-deleted")
            try await runtime.stop()
            guard try hash(layers.appendingPathComponent("Base.ext4")) == baseHash else {
                throw ComputerError("The read-only base was modified by guest writes")
            }
            _ = try await runtime.start(computer: computer, directory: directory, cache: store.cache, kernel: store.kernel)
            try await check(runtime, "test \"$(cat /workspace/keep)\" = user-data; test \"$(cat /etc/overlay-user)\" = user-edit; test ! -e /etc/overlay-deleted")
            try await runtime.stop()
            print("PASS: overlay mount, immutable base, writes/deletions and restart persistence")

            let candidate = ContainerDiskState(previousGeneration: original.generation,
                imageReference: computer.imageReference, imageDigest: "fixture-v2")
            let next = candidate.directory(in: directory)
            try FileManager.default.copyItem(at: layers, to: next)
            try await seedBase(next.appendingPathComponent("Base.ext4"), value: "new", store: store)
            _ = try await runtime.start(computer: computer, directory: directory, cache: store.cache,
                                        kernel: store.kernel, preparedState: candidate)
            try await check(runtime, "test \"$(cat /etc/overlay-base)\" = new; test \"$(cat /workspace/keep)\" = user-data; test \"$(cat /etc/overlay-user)\" = user-edit; test ! -e /etc/overlay-deleted; echo candidate > /workspace/staged")
            try await runtime.stop()
            guard try ContainerDiskState.load(in: directory) == original else { throw ComputerError("Candidate activated before verification") }
            _ = try await runtime.start(computer: computer, directory: directory, cache: store.cache, kernel: store.kernel)
            try await check(runtime, "test \"$(cat /etc/overlay-base)\" = old; test ! -e /workspace/staged")
            try await runtime.stop()
            try candidate.activate(in: directory)
            _ = try await runtime.start(computer: computer, directory: directory, cache: store.cache, kernel: store.kernel)
            try await check(runtime, "test \"$(cat /etc/overlay-base)\" = new; test \"$(cat /workspace/staged)\" = candidate; test ! -e /etc/overlay-deleted")
            try await runtime.stop()
            print("PASS: new base visible, local overrides and whiteouts retained, staged writes isolated, atomic activation")
            await store.updateImage(session)
            guard store.error == nil, session.phase == .stopped else {
                throw ComputerError(store.error ?? "Store image update did not finish")
            }
            let updated = try ContainerDiskState.load(in: directory)
            guard updated.generation != candidate.generation else { throw ComputerError("Store did not activate the fetched image") }
            _ = try await runtime.start(computer: computer, directory: directory, cache: store.cache, kernel: store.kernel)
            try await check(runtime, "test \"$(cat /workspace/keep)\" = user-data; test \"$(cat /etc/overlay-user)\" = user-edit; test ! -e /etc/overlay-deleted; test ! -e /etc/overlay-base")
            try await runtime.stop()
            await store.updateImage(session)
            guard store.error == nil, try ContainerDiskState.load(in: directory) == updated else {
                throw ComputerError("An unchanged remote image replaced the disk")
            }
            print("PASS: real pull/update/boot-check/commit flow and already-current detection")
            try FileManager.default.removeItem(at: root)
        } catch {
            try? await runtime.stop()
            print("Overlay fixture retained for diagnosis: \(root.path)")
            throw error
        }
    }

    static func makeUIStore() throws -> ComputerStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleOverlayUI-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        let session = ComputerSession(ComputerTemplate.shell.makeComputer(name: "Overlay UI fixture"))
        session.phase = .running
        session.container = ContainerComputer()
        store.sessions = [session]
        store.selection = session.id
        return store
    }

    private static func check(_ runtime: ContainerComputer, _ command: String) async throws {
        let result = try await runtime.execute("set -eu; " + command)
        guard result.contains("[Exit 0]") else { throw ComputerError("Overlay assertion failed: \(command)\n\(result)") }
    }

    private static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func seedBase(_ file: URL, value: String, store: ComputerStore) async throws {
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: store.kernel, platform: .linuxArm),
            initialFilesystem: .block(format: "ext4", source: store.cache.appendingPathComponent("initfs-0.43.0.ext4").path,
                                      destination: "/", options: ["ro"]))
        let pod = try LinuxPod("overlay-seed-\(UUID().uuidString.lowercased())", vmm: vmm) { config in
            config.cpus = 2; config.memoryInBytes = 1_073_741_824
        }
        let output = ComputerOutput()
        try await pod.addContainer("seed", rootfs: .block(format: "ext4", source: file.path, destination: "/")) { config in
            config.process.arguments = ["/bin/sh", "-c", "set -eu; for name in base user deleted; do printf '%s\\n' \"$1\" > /etc/overlay-$name; done; sync", "seed", value]
            config.process.environmentVariables = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
            config.process.stdout = output; config.process.stderr = output
        }
        do {
            try await pod.create()
            try await pod.startContainer("seed")
            let status = try await pod.waitContainer("seed", timeoutInSeconds: 30)
            guard status.exitCode == 0 else { throw ComputerError(output.text()) }
            try await pod.stop()
        } catch { try? await pod.stop(); throw error }
    }
}
