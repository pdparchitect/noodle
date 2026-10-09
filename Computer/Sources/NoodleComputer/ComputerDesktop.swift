import ComputerCore
import Containerization
import ContainerizationExtras
import CoreGraphics
import Foundation
import Surface
import Virtualization

/// Gives a Linux desktop's VM a virtio GPU with USB keyboard and pointer. On macOS 27 that is the app's own 3D GPU,
/// shown by VirglDisplay; before it, VZ's 2D GPU in a VZVirtualMachineView. Agents and remote viewers use `surface`
/// either way, because neither view can be captured.
final class NativeDisplay: VZInstanceExtension, @unchecked Sendable {
    static let fixedSize = CGSize(width: 1920, height: 1200)
    let surface: DesktopSurface
    private let lock = NSLock()
    private var created: (machine: VZVirtualMachine, queue: DispatchQueue)?
    var machine: VZVirtualMachine? { lock.withLock { created?.machine } }
    /// The queue every call to `machine` must run on.
    var machineQueue: DispatchQueue? { lock.withLock { created?.queue } }

    /// Brings the display to the size the setting asks for now, rather than at the
    /// view's next resize: the view's size while resizing, else the fixed size. The VM
    /// takes calls only on its own queue.
    func apply(resizes: Bool, viewPixels: CGSize) {
        let size = resizes ? viewPixels : Self.fixedSize
        if #available(macOS 27, *), let virgl {
            if size.width >= 1, size.height >= 1 { virgl.resize(width: Int(size.width), height: Int(size.height)) }
            return
        }
        guard size.width >= 1, size.height >= 1, let (machine, queue) = lock.withLock({ created }) else { return }
        queue.async {
            guard let display = machine.graphicsDevices.first?.displays.first, display.sizeInPixels != size else { return }
            try? display.reconfigure(sizeInPixels: size)
        }
    }

    init(dial: @escaping @Sendable () async throws -> FileHandle) {
        surface = DesktopSurface(dial: dial)
    }

    func configureVZ(_ config: inout VZVirtualMachineConfiguration, allocator: any AddressAllocator<Character>,
                     storageDeviceCount: Int, mountsByID: [String: [Containerization.Mount]]) throws {
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        // On macOS 27 the desktop draws with the Mac's GPU, through a virtio-gpu of the app's own.
        if #available(macOS 27, *), VirglGPU.isAvailable {
            let gpu = VirglGPU()
            lock.withLock { renderer = gpu }
            config.customVirtioDevices = [gpu.configuration()]
            return
        }
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        // The desktop keeps this resolution unless it resizes with its window.
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: Int(Self.fixedSize.width),
                                                                   heightInPixels: Int(Self.fixedSize.height))]
        config.graphicsDevices = [graphics]
    }
    private var renderer: AnyObject?
    @available(macOS 27, *)
    var virgl: VirglGPU? { lock.withLock { renderer as? VirglGPU } }

    func didCreate(_ instance: VZVirtualMachineInstance) throws {
        lock.withLock { created = (instance.vzVirtualMachine, instance.vmQueue) }
    }
}

/// Client of the image's desktop-surface helper, which serves the X screen and takes
/// input on a guest vsock port. It sends only the tiles that changed; the canvas here
/// keeps the rest. Requests are serialized: one connection, one request at a time.
final class DesktopSurface: @unchecked Sendable {
    static let port: UInt32 = 5100
    private let dial: @Sendable () async throws -> FileHandle
    private let queue = DispatchQueue(label: "com.pdparchitect.noodle.computer.desktop-surface")
    private let connecting = Connector()
    private var canvas: CGContext?

    init(dial: @escaping @Sendable () async throws -> FileHandle) { self.dial = dial }

    func frame() async throws -> (image: CGImage, size: CGSize) {
        try await perform { try self.readFrame($0) }
    }

    func send(_ input: SurfaceInput) async throws {
        // The desktop takes whole key presses, so a held key is pressed once and its release dropped.
        if case .hold(_, pressed: false) = input { return }
        let request = Self.request(for: input)
        try await perform { try Self.write(request, to: $0) }
    }

    /// Puts text on the guest's clipboard and pastes it into the focused app.
    func paste(_ text: String) async throws {
        let bytes = Data(text.utf8.prefix(Self.clipboardLimit))
        let request = Data([6]) + withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { Data($0) } + bytes
        try await perform { try Self.write(request, to: $0) }
    }

    /// Copies in the focused guest app, or takes a terminal's selection, and returns the text.
    func copy() async throws -> String {
        try await perform { handle in
            try Self.write(Data([7]), to: handle)
            let count = Int(try Self.words(1, from: handle)[0])
            guard count <= Self.clipboardLimit else { throw ComputerError("The desktop sent too much clipboard text.") }
            return String(decoding: try Self.read(count, from: handle), as: UTF8.self)
        }
    }
    static let clipboardLimit = 1 << 20

    func close() async { try? await connecting.reset()?.close() }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (FileHandle) throws -> T) async throws -> T {
        let handle = try await connecting.handle(dial)
        guard !Task.isCancelled else { throw CancellationError() }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try body(handle) }) }
            }
        } catch {
            // A broken or confused stream cannot be resynchronized; start a new one next time.
            try? await connecting.reset()?.close()
            throw error
        }
    }

    private func readFrame(_ handle: FileHandle) throws -> (image: CGImage, size: CGSize) {
        try Self.write(Data([1]), to: handle)
        let header = try Self.words(3, from: handle)
        let (width, height, tiles) = (Int(header[0]), Int(header[1]), Int(header[2]))
        guard (1...16_384).contains(width), (1...16_384).contains(height), tiles <= width * height else {
            throw ComputerError("The desktop sent an invalid frame.")
        }
        if canvas?.width != width || canvas?.height != height {
            canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let canvas, let pixels = canvas.data?.assumingMemoryBound(to: UInt8.self) else {
            throw ComputerError("The desktop frame could not be drawn.")
        }
        for _ in 0..<tiles {
            let tile = try Self.words(4, from: handle).map(Int.init)
            let (x, y, w, h) = (tile[0], tile[1], tile[2], tile[3])
            guard w > 0, h > 0, x + w <= width, y + h <= height else { throw ComputerError("The desktop sent an invalid frame.") }
            let rows = try Self.read(w * h * 4, from: handle)
            rows.withUnsafeBytes { source in
                for row in 0..<h {
                    memcpy(pixels + (y + row) * canvas.bytesPerRow + x * 4, source.baseAddress! + row * w * 4, w * 4)
                }
            }
        }
        guard let image = canvas.makeImage() else { throw ComputerError("The desktop frame could not be drawn.") }
        return (image, CGSize(width: width, height: height))
    }

    static func request(for input: SurfaceInput) -> Data {
        func words(_ values: [Double]) -> Data {
            values.reduce(into: Data()) { data, value in
                withUnsafeBytes(of: Int32(clamping: Int(value.rounded())).littleEndian) { data.append(contentsOf: $0) }
            }
        }
        switch input {
        case .pointer(let phase, let x, let y, _):
            let code: [SurfaceInput.Phase: UInt8] = [.move: 0, .down: 1, .drag: 2, .up: 3]
            return Data([2, code[phase] ?? 0]) + words([x, y])
        case .scroll(let x, let y, let dx, let dy):
            return Data([3]) + words([x, y, dx, dy])
        case .key(let key):
            let keysyms: [SurfaceInput.Key: UInt32] = [.enter: 0xff0d, .tab: 0xff09, .escape: 0xff1b, .backspace: 0xff08,
                                                       .space: 0x20, .left: 0xff51, .up: 0xff52, .right: 0xff53, .down: 0xff54]
            return Data([4]) + withUnsafeBytes(of: (keysyms[key] ?? 0).littleEndian) { Data($0) }
        case .hold(let key, _):
            return request(for: SurfaceInput.Key(rawValue: key).map(SurfaceInput.key) ?? .text(key))
        case .text(let text):
            let bytes = Data(text.utf8.prefix(65_536))
            return Data([5]) + withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { Data($0) } + bytes
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) throws { try handle.write(contentsOf: data) }

    private static func read(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw ComputerError("The desktop connection closed.")
            }
            data.append(chunk)
        }
        return data
    }

    private static func words(_ count: Int, from handle: FileHandle) throws -> [UInt32] {
        let data = try read(count * 4, from: handle)
        return (0..<count).map { index in
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)) }
        }
    }

    /// Callers that arrive while a dial is under way share it.
    private actor Connector {
        private var dialing: Task<FileHandle, Error>?
        func handle(_ dial: @escaping @Sendable () async throws -> FileHandle) async throws -> FileHandle {
            let task = dialing ?? Task { try await dial() }
            dialing = task
            do { return try await task.value } catch {
                dialing = nil
                throw error
            }
        }
        func reset() async -> FileHandle? {
            defer { dialing = nil }
            return try? await dialing?.value
        }
    }
}
