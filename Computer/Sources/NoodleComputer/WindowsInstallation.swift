import AppKit
import ComputerCore
import CryptoKit
import Darwin
import Foundation
import Virtualization

/// Makes a Windows computer's disk. The first time, it downloads Windows 11 for Arm from Microsoft, turns it into
/// install media, installs it in a VM nobody sees, and keeps the result, set up only as far as Windows' own first
/// start, as the base every later Windows computer is cloned from.
@available(macOS 27, *)
enum WindowsInstallation {
    typealias Report = @MainActor @Sendable (_ status: String, _ fraction: Double?, _ detail: String?) -> Void
    /// The base image's format; a base made by an older one is made again.
    static let baseVersion = 5

    static func prepare(computer: Computer, directory: URL, cache: URL, report: @escaping Report) async throws {
        // Without this, macOS slows the app to a crawl once it is in the background, and the Mac may sleep.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Installing Windows")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let root = cache.appendingPathComponent("Windows", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.appendingPathComponent("Base.img")
        let marker = root.appendingPathComponent("Base.json")
        let current = (try? JSONDecoder().decode([String: Int].self, from: Data(contentsOf: marker)))?["version"] == baseVersion
        if !current || !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.removeItem(at: base)
            try await makeBase(at: base, in: root, report: report)
            try JSONEncoder().encode(["version": baseVersion]).write(to: marker, options: .atomic)
        }
        try Task.checkCancellation()
        await report("Copying Windows…", nil, nil)
        let disk = directory.appendingPathComponent("Disk.img")
        if clonefile(base.path, disk.path, 0) != 0 { try FileManager.default.copyItem(at: base, to: disk) }
        // setup.ps1 grows Windows' partition into whatever the computer has beyond the base's 64 GB.
        let size = UInt64(computer.diskGiB) * 1_073_741_824
        let handle = try FileHandle(forWritingTo: disk)
        defer { try? handle.close() }
        if try handle.seekToEnd() < size { try handle.truncate(atOffset: size) }
    }

    private static func makeBase(at base: URL, in root: URL, report: @escaping Report) async throws {
        await report("Finding Windows 11 for Arm…", nil, nil)
        let image = try await catalogImage(in: root)
        let media = root.appendingPathComponent("Media.img")
        let mediaMarker = root.appendingPathComponent("Media.json")
        // Install media from an earlier attempt that did not finish is used again.
        let made = ["sha1": image.sha1, "version": String(baseVersion)]
        let madeFrom = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: mediaMarker))
        let hasMedia = madeFrom == made && FileManager.default.fileExists(atPath: media.path)
        // Running out of space half an hour in is worse than not starting.
        if let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            try WindowsInstallSpace.check(available: available,
                                          hasDownload: FileManager.default.fileExists(atPath: root.appendingPathComponent(image.fileName).path),
                                          hasMedia: hasMedia)
        }
        if !hasMedia {
            try? FileManager.default.removeItem(at: mediaMarker)
            try await makeMedia(image, at: media, in: root, report: report)
            try JSONEncoder().encode(made).write(to: mediaMarker, options: .atomic)
        }

        let staging = root.appendingPathComponent("Base.staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let disk = staging.appendingPathComponent("Disk.img")
        guard FileManager.default.createFile(atPath: disk.path, contents: nil) else { throw ComputerError("Cannot create the Windows disk.") }
        try FileHandle(forWritingTo: disk).truncate(atOffset: 64 * 1_073_741_824)
        await report("Installing Windows…", nil, nil)
        try await WindowsInstallRun().run(directory: staging, media: media, report: report)
        try FileManager.default.moveItem(at: disk, to: base)
        // The base is all later computers need; until it is made, a retry needs no new download.
        try? FileManager.default.removeItem(at: media)
        try? FileManager.default.removeItem(at: mediaMarker)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(image.fileName))
    }

    /// Downloads Windows unless it is already here, and turns it into install media.
    private static func makeMedia(_ image: WindowsCatalog.Image, at media: URL, in root: URL, report: @escaping Report) async throws {
        let esd = root.appendingPathComponent(image.fileName)
        if try await !verify(esd, image, report: report, quietly: true) {
            try? FileManager.default.removeItem(at: esd)
            await report("Downloading Windows 11 for Arm…", 0, nil)
            let reporter = DownloadProgressReporter { update in
                Task { @MainActor in report("Downloading Windows 11 for Arm…", update.fraction, update.detail) }
            }
            let (file, response) = try await reporter.download(for: URLRequest(url: image.url))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: file)
                throw ComputerError("Microsoft's server did not send Windows (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            try FileManager.default.moveItem(at: file, to: esd)
            guard try await verify(esd, image, report: report, quietly: false) else {
                try? FileManager.default.removeItem(at: esd)
                throw ComputerError("The Windows download was damaged. Try again.")
            }
        }
        try await buildMedia(from: esd, to: media, in: root, report: report)
    }

    // MARK: Download

    private static func catalogImage(in root: URL) async throws -> WindowsCatalog.Image {
        let (cab, response) = try await URLSession.shared.data(from: WindowsCatalog.productsURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ComputerError("Microsoft's Windows catalogue is unavailable. Try again later.")
        }
        let file = root.appendingPathComponent("products.cab")
        try cab.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // The catalogue is a CAB; the system's tar reads CABs.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xOf", file.path, "products.xml"]
        let pipe = Pipe()
        tar.standardOutput = pipe
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        let xml = pipe.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0, !xml.isEmpty else { throw ComputerError("Microsoft's Windows catalogue could not be read.") }
        return try WindowsCatalog.armProfessional(in: xml)
    }

    /// Whether `file` is the catalogue's image, by size and SHA-1.
    private static func verify(_ file: URL, _ image: WindowsCatalog.Image, report: @escaping Report, quietly: Bool) async throws -> Bool {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == image.size else { return false }
        if !quietly { await report("Checking the download…", 0, nil) }
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = Insecure.SHA1()
            var done: Int64 = 0
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
                done += Int64(chunk.count)
                if !quietly, done % (256 << 20) < Int64(chunk.count) {
                    let fraction = Double(done) / Double(image.size)
                    Task { @MainActor in report("Checking the download…", fraction, nil) }
                }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler { try await task.value == image.sha1 } onCancel: { task.cancel() }
    }

    // MARK: Media

    /// The ESD's setup files, a boot.wim with WinPE and Windows Setup, Windows 11 Pro split under FAT32's 4 GB
    /// limit, the answer file, install.cmd, the Noodle agent and the virtio drivers, on a FAT32 disk.
    private static func buildMedia(from esd: URL, to media: URL, in root: URL, report: @escaping Report) async throws {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Windows"),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("install.cmd").path) else {
            throw ComputerError("The Windows installer files are missing. Rebuild \(ComputerAppIdentity.name).")
        }
        let staging = root.appendingPathComponent("Media.staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let timeZone = WindowsAnswers.windowsTimeZone(for: TimeZone.current.identifier)

        let work = Task.detached(priority: .userInitiated) { () throws -> Void in
            let wim = try Wimlib.load()
            let source = try wim.open(esd)
            let images = try wim.imageCount(source)
            guard images >= 4, let pro = (1...images).first(where: { wim.property(source, $0, "WINDOWS/EDITIONID") == "Professional" }) else {
                throw ComputerError("This Windows download has no Windows 11 Pro.")
            }
            func progress(_ status: String) -> (Double) -> Bool {
                { fraction in
                    Task { @MainActor in report(status, fraction, nil) }
                    return !Task.isCancelled
                }
            }
            try wim.extract(source, image: 1, to: staging, progress: progress("Preparing the installer…"))
            let boot = try wim.create()
            try wim.export(source, image: 2, to: boot, boot: false)
            try wim.export(source, image: 3, to: boot, boot: true)
            // WinPE starts noodle-start.cmd instead of Windows Setup, with the serial driver at hand.
            let overlay = root.appendingPathComponent("Boot.overlay", isDirectory: true)
            try? FileManager.default.removeItem(at: overlay)
            try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: overlay) }
            try Data("[LaunchApps]\r\n%WINDIR%\\System32\\cmd.exe, /c %SYSTEMDRIVE%\\noodle-start.cmd\r\n".utf8)
                .write(to: overlay.appendingPathComponent("winpeshl.ini"))
            try copyScript(resources.appendingPathComponent("noodle-start.cmd"), to: overlay.appendingPathComponent("noodle-start.cmd"))
            try FileManager.default.copyItem(at: resources.appendingPathComponent("drivers/vioserial"), to: overlay.appendingPathComponent("vioserial"))
            let bootWIM = staging.appendingPathComponent("sources/boot.wim")
            try wim.write(boot, to: bootWIM, progress: progress("Preparing Windows Setup…"))
            wim.free(boot)
            // An exported image shares its metadata with the ESD until written, so it is changed afterwards.
            let written = try wim.open(bootWIM, writable: true)
            try wim.add(written, image: 2, from: overlay.appendingPathComponent("winpeshl.ini"), at: "/Windows/System32/winpeshl.ini")
            try wim.add(written, image: 2, from: overlay.appendingPathComponent("noodle-start.cmd"), at: "/noodle-start.cmd")
            try wim.add(written, image: 2, from: overlay.appendingPathComponent("vioserial"), at: "/noodle/vioserial")
            try wim.overwrite(written)
            wim.free(written)
            let install = try wim.create()
            try wim.export(source, image: pro, to: install, boot: false)
            let parts = staging.appendingPathComponent("sources/install.swm")
            do {
                try wim.split(install, to: parts, partSize: 3800 << 20, progress: progress("Preparing Windows 11 Pro…"))
            } catch {
                // Should splitting an unwritten image not work, write it once and split that.
                let whole = root.appendingPathComponent("install.wim")
                defer { try? FileManager.default.removeItem(at: whole) }
                try wim.write(install, to: whole, progress: progress("Preparing Windows 11 Pro…"))
                let written = try wim.open(whole)
                try wim.split(written, to: parts, partSize: 3800 << 20, progress: progress("Preparing Windows 11 Pro…"))
                wim.free(written)
            }
            wim.free(install)
            wim.free(source)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }

        let noodle = staging.appendingPathComponent("noodle", isDirectory: true)
        try FileManager.default.createDirectory(at: noodle, withIntermediateDirectories: true)
        try Data(WindowsAnswers.setup().utf8).write(to: staging.appendingPathComponent("autounattend.xml"))
        let password = (0..<4).map { _ in UUID().uuidString.prefix(8) }.joined(separator: "-")
        try Data(WindowsAnswers.firstBoot(user: "noodle", password: password, timeZone: timeZone).utf8)
            .write(to: noodle.appendingPathComponent("unattend.xml"))
        try copyScript(resources.appendingPathComponent("install.cmd"), to: noodle.appendingPathComponent("install.cmd"))
        for item in ["guest", "drivers"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(item), to: noodle.appendingPathComponent(item))
        }
        await report("Writing the installer disk…", 0, nil)
        let write = Task.detached(priority: .userInitiated) {
            try FATImage.write(directory: staging, to: media, label: "WINSETUP") { done, total in
                guard total > 0, done % (512 << 20) < (8 << 20) || done == total else { return }
                Task { @MainActor in report("Writing the installer disk…", Double(done) / Double(total), nil) }
            }
        }
        try await withTaskCancellationHandler { try await write.value } onCancel: { write.cancel() }
    }
}

/// cmd.exe reads batch files with Windows line endings; its labels misbehave without them.
@available(macOS 27, *)
private func copyScript(_ source: URL, to destination: URL) throws {
    let text = try String(contentsOf: source, encoding: .utf8)
    try Data(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: destination)
}

/// The headless install: WinPE boots the media, runs noodle\install.cmd, and says how it goes over the
/// virtio-serial port "org.noodle.progress", ending with "step: done" and a shutdown.
@available(macOS 27, *)
@MainActor private final class WindowsInstallRun: NSObject, VZVirtualMachineDelegate {
    private var machine: VZVirtualMachine?
    private var host: FileHandle?
    private var pending = ""
    private var outcome: String?
    private var tail: [String] = []
    private var stopped: CheckedContinuation<Error?, Never>?

    func run(directory: URL, media: URL, report: @escaping WindowsInstallation.Report) async throws {
        var pair: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        let host = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        let guest = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        self.host = host
        defer { host.readabilityHandler = nil }
        host.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            Task { @MainActor in self?.receive(text, report: report) }
        }
        let port = VZVirtioConsolePortConfiguration()
        port.name = "org.noodle.progress"
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: guest, fileHandleForWriting: guest)
        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = port
        var gpu: WindowsGPU?
        #if NOODLE_DEV_HOOKS
        // `-WindowsInstallScreen YES`: the install's screen, every 20 seconds, as base64 PNG lines on stdout.
        if UserDefaults.standard.bool(forKey: "WindowsInstallScreen") {
            let screen = WindowsGPU(accelerated: false)
            screen.servesFirmware = true
            let last = LastFrameTime()
            screen.onFrame = { image in
                guard last.due(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                print("WINDOWS SCREEN \(png.base64EncodedString())")
            }
            gpu = screen
        }
        #endif
        let configuration = try WindowsComputer.configuration(cpus: min(4, ProcessInfo.processInfo.processorCount), memoryGiB: 4,
                                                              directory: directory, media: media, network: false, gpu: gpu, consoles: [console])
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = self
        self.machine = machine
        try await machine.start()
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90 * 60))
            guard !Task.isCancelled, let self, self.machine?.state == .running else { return }
            self.outcome = self.outcome ?? "failed: the installation took too long"
            try? await self.machine?.stop()
            self.stopped?.resume(returning: nil); self.stopped = nil
        }
        defer { deadline.cancel() }
        let error = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in stopped = continuation }
        } onCancel: {
            Task { @MainActor in
                try? await machine.stop()
                self.stopped?.resume(returning: CancellationError()); self.stopped = nil
            }
        }
        if let error { throw error }
        try Task.checkCancellation()
        // The last lines can still be on their way when the machine stops.
        if outcome == nil { try? await Task.sleep(for: .seconds(1)) }
        guard outcome == "done" else {
            let reason = outcome.map { String($0.dropFirst("failed: ".count)) } ?? "Windows stopped before it was installed"
            throw ComputerError("Windows could not be installed (\(reason)). \(tail.suffix(6).joined(separator: " "))")
        }
    }

    private func receive(_ text: String, report: WindowsInstallation.Report) {
        pending += text
        var lines = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        pending = lines.removeLast()
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            tail = Array((tail + [line.trimmingCharacters(in: .whitespaces)]).suffix(20))
            switch WindowsInstallProgress.parse(line) {
            case .step(let step) where step == "done" || step.hasPrefix("failed"):
                outcome = step
            case .step(let step):
                report("Installing Windows: \(step.lowercased())…", nil, nil)
            case .fraction(let fraction):
                report("Installing Windows: copying Windows…", fraction, nil)
            case nil: break
            }
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.stopped?.resume(returning: nil); self.stopped = nil }
    }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in self.stopped?.resume(returning: error); self.stopped = nil }
    }
}

#if NOODLE_DEV_HOOKS
private final class LastFrameTime: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func due() -> Bool { lock.withLock { guard Date().timeIntervalSince(last) > 20 else { return false }; last = Date(); return true } }
}
#endif

/// libwim, the library half of wimlib (LGPL), which the build puts in the app's Frameworks.
private final class Wimlib: @unchecked Sendable {
    typealias Progress = @convention(c) (Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
    private let globalInit: @convention(c) (Int32) -> Int32
    private let openWIM: @convention(c) (UnsafePointer<CChar>, Int32, UnsafeMutablePointer<OpaquePointer?>, Progress?, UnsafeMutableRawPointer?) -> Int32
    private let register: @convention(c) (OpaquePointer, Progress?, UnsafeMutableRawPointer?) -> Void
    private let extractImage: @convention(c) (OpaquePointer, Int32, UnsafePointer<CChar>, Int32) -> Int32
    private let createWIM: @convention(c) (Int32, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private let exportImage: @convention(c) (OpaquePointer, Int32, OpaquePointer, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32
    private let writeWIM: @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, Int32, UInt32) -> Int32
    private let splitWIM: @convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt64, Int32) -> Int32
    private let info: @convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32
    private let imageProperty: @convention(c) (OpaquePointer, Int32, UnsafePointer<CChar>) -> UnsafePointer<CChar>?
    private let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>?
    private let addTree: @convention(c) (OpaquePointer, Int32, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32) -> Int32
    private let overwriteWIM: @convention(c) (OpaquePointer, Int32, UInt32) -> Int32
    private let freeWIM: @convention(c) (OpaquePointer) -> Void

    private static let shared = Result { try Wimlib() }
    static func load() throws -> Wimlib { try shared.get() }

    private init() throws {
        guard let path = Bundle.main.privateFrameworksURL?.appendingPathComponent("libwim.15.dylib").path,
              let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw ComputerError("The Windows image library is missing. Rebuild \(ComputerAppIdentity.name).")
        }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw ComputerError("The Windows image library lacks \(name).") }
            return unsafeBitCast(pointer, to: type)
        }
        globalInit = try symbol("wimlib_global_init", (@convention(c) (Int32) -> Int32).self)
        openWIM = try symbol("wimlib_open_wim_with_progress", (@convention(c) (UnsafePointer<CChar>, Int32, UnsafeMutablePointer<OpaquePointer?>, Progress?, UnsafeMutableRawPointer?) -> Int32).self)
        register = try symbol("wimlib_register_progress_function", (@convention(c) (OpaquePointer, Progress?, UnsafeMutableRawPointer?) -> Void).self)
        extractImage = try symbol("wimlib_extract_image", (@convention(c) (OpaquePointer, Int32, UnsafePointer<CChar>, Int32) -> Int32).self)
        createWIM = try symbol("wimlib_create_new_wim", (@convention(c) (Int32, UnsafeMutablePointer<OpaquePointer?>) -> Int32).self)
        exportImage = try symbol("wimlib_export_image", (@convention(c) (OpaquePointer, Int32, OpaquePointer, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Int32).self)
        writeWIM = try symbol("wimlib_write", (@convention(c) (OpaquePointer, UnsafePointer<CChar>, Int32, Int32, UInt32) -> Int32).self)
        splitWIM = try symbol("wimlib_split", (@convention(c) (OpaquePointer, UnsafePointer<CChar>, UInt64, Int32) -> Int32).self)
        info = try symbol("wimlib_get_wim_info", (@convention(c) (OpaquePointer, UnsafeMutableRawPointer) -> Int32).self)
        imageProperty = try symbol("wimlib_get_image_property", (@convention(c) (OpaquePointer, Int32, UnsafePointer<CChar>) -> UnsafePointer<CChar>?).self)
        errorString = try symbol("wimlib_get_error_string", (@convention(c) (Int32) -> UnsafePointer<CChar>?).self)
        freeWIM = try symbol("wimlib_free", (@convention(c) (OpaquePointer) -> Void).self)
        overwriteWIM = try symbol("wimlib_overwrite", (@convention(c) (OpaquePointer, Int32, UInt32) -> Int32).self)
        addTree = try symbol("wimlib_add_tree", (@convention(c) (OpaquePointer, Int32, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32) -> Int32).self)
        try check(globalInit(0))
    }

    private func check(_ code: Int32) throws {
        guard code != 0 else { return }
        if code == 76 { throw CancellationError() } // WIMLIB_ERR_ABORTED_BY_PROGRESS
        let message = errorString(code).map { String(cString: $0) } ?? "error \(code)"
        throw ComputerError("The Windows image could not be prepared: \(message).")
    }

    func open(_ url: URL, writable: Bool = false) throws -> OpaquePointer {
        var wim: OpaquePointer?
        try check(openWIM(url.path, writable ? 4 : 0, &wim, nil, nil)) // WIMLIB_OPEN_FLAG_WRITE_ACCESS
        guard let wim else { throw ComputerError("The Windows image could not be opened.") }
        return wim
    }

    func create() throws -> OpaquePointer {
        var wim: OpaquePointer?
        try check(createWIM(2, &wim)) // WIMLIB_COMPRESSION_TYPE_LZX: Windows Setup reads it, not solid LZMS
        guard let wim else { throw ComputerError("The Windows image could not be prepared.") }
        return wim
    }

    func free(_ wim: OpaquePointer) { freeWIM(wim) }

    func imageCount(_ wim: OpaquePointer) throws -> Int {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 512)
        try check(info(wim, buffer))
        return Int(buffer.load(fromByteOffset: 16, as: UInt32.self)) // after the 16-byte GUID
    }

    func property(_ wim: OpaquePointer, _ image: Int, _ name: String) -> String? {
        imageProperty(wim, Int32(image), name).map { String(cString: $0) }
    }

    func export(_ source: OpaquePointer, image: Int, to destination: OpaquePointer, boot: Bool) throws {
        try check(exportImage(source, Int32(image), destination, nil, nil, boot ? 1 : 0)) // WIMLIB_EXPORT_FLAG_BOOT
    }

    /// Puts a file or folder into an image, replacing what is there; the source must stay until the image is written.
    func add(_ wim: OpaquePointer, image: Int, from source: URL, at path: String) throws {
        try check(addTree(wim, Int32(image), source.path, path, 0))
    }

    /// Writes an opened WIM's changes back into its file.
    func overwrite(_ wim: OpaquePointer) throws {
        try check(overwriteWIM(wim, 0, UInt32(ProcessInfo.processInfo.activeProcessorCount)))
    }

    func extract(_ wim: OpaquePointer, image: Int, to directory: URL, progress: @escaping (Double) -> Bool) throws {
        try observing(wim, progress) { try check(extractImage(wim, Int32(image), directory.path, 0)) }
    }

    func write(_ wim: OpaquePointer, to url: URL, progress: @escaping (Double) -> Bool) throws {
        let threads = UInt32(ProcessInfo.processInfo.activeProcessorCount)
        try observing(wim, progress) { try check(writeWIM(wim, url.path, -1, 0, threads)) } // all images
    }

    func split(_ wim: OpaquePointer, to url: URL, partSize: UInt64, progress: @escaping (Double) -> Bool) throws {
        try observing(wim, progress) { try check(splitWIM(wim, url.path, partSize, 0)) }
    }

    /// Reports extraction (message 4) and writing (message 12) as fractions; `progress` returning false aborts.
    private final class Observer {
        let progress: (Double) -> Bool
        var last = Date.distantPast
        init(_ progress: @escaping (Double) -> Bool) { self.progress = progress }
    }
    private func observing(_ wim: OpaquePointer, _ progress: @escaping (Double) -> Bool, _ body: () throws -> Void) throws {
        let observer = Observer(progress)
        let context = Unmanaged.passRetained(observer).toOpaque()
        defer { register(wim, nil, nil); Unmanaged<Observer>.fromOpaque(context).release() }
        register(wim, { message, info, context in
            guard let info, let context else { return 0 }
            let observer = Unmanaged<Observer>.fromOpaque(context).takeUnretainedValue()
            let offsets: (total: Int, done: Int)
            switch message {
            case 4: offsets = (40, 48)  // extract: image, flags, four strings, then total and completed bytes
            case 12: offsets = (0, 16)  // write streams: total bytes, total streams, completed bytes
            default: return Task.isCancelled ? 1 : 0
            }
            let total = info.load(fromByteOffset: offsets.total, as: UInt64.self)
            let done = info.load(fromByteOffset: offsets.done, as: UInt64.self)
            guard Date().timeIntervalSince(observer.last) > 0.25 || done == total else { return 0 }
            observer.last = Date()
            return observer.progress(total > 0 ? Double(done) / Double(total) : 0) ? 0 : 1 // WIMLIB_PROGRESS_STATUS_ABORT
        }, context)
        try body()
    }
}
