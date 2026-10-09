import ComputerCore
import AppKit
import IOSurface
import Darwin
import Foundation
import OpenGL
import OpenGL.GL3
import ObjectiveC
import os
import SwiftUI
import Virtualization

private let log = Logger(subsystem: "com.pdparchitect.noodle.computer", category: "GPU3D")

/// A Linux desktop's virtio-gpu with 3D: the guest's OpenGL runs on the Mac's GPU through virglrenderer, and the
/// scanout is copied on the GPU into the surface the view shows. It needs macOS 27's custom Virtio devices; without
/// them, or without the library, desktops keep VZ's own 2D GPU.
@available(macOS 27, *)
final class VirglGPU: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    static var isAvailable: Bool { Virgl.shared != nil }

    private struct Backing {
        var mappings: [VZGuestMemoryMapping]
        var iovecs: UnsafeMutablePointer<iovec>
    }
    private let queue = DispatchQueue(label: "com.pdparchitect.noodle.computer.virgl-gpu")
    private var device: VZCustomVirtioDevice?
    private var backings: [UInt32: Backing] = [:]
    private var contexts: Set<UInt32> = []
    private var pending: [(fence: Int32, element: VZVirtioQueueElement, reply: Data)] = []
    private var nextFence: Int32 = 0
    private var signalled: Int32 = 0
    private var timer: DispatchSourceTimer?
    private var commands = 0, submitted = 0
    static let screen = (width: 1920, height: 1200)
    private var size = (width: VirglGPU.screen.width, height: VirglGPU.screen.height)
    /// A size change waits in events_read until the guest asks for the display info again.
    private var displayChanged = false
    private var scanout: UInt32 = 0
    private var dirty = false
    private var frameTimer: DispatchSourceTimer?
    private var pixels: UnsafeMutableRawPointer?
    private let frames = NSLock()
    private var frameHandler: (@Sendable (VirglFrame) -> Void)?
    private var latest: VirglFrame?
    /// Three surfaces in turn, so the one on screen is never the one being drawn into.
    private var surfaces: [IOSurface] = []
    private var nextSurface = 0
    /// Frames shown, and the time their copies took in milliseconds, for the development harness.
    private(set) var presented = 0
    private var cursorHandler: (@Sendable (CGImage?, CGPoint) -> Void)?
    /// Called on the main queue with the guest's pointer image and hot spot, or nil to hide it.
    var onCursor: (@Sendable (CGImage?, CGPoint) -> Void)? {
        get { frames.withLock { cursorHandler } }
        set { frames.withLock { cursorHandler = newValue } }
    }
    private var cursorFrame: (CGImage?, CGPoint)?
    var lastCursor: (CGImage?, CGPoint)? { frames.withLock { cursorFrame } }

    /// Offers the guest a new screen size; Linux picks it up as its preferred mode.
    func resize(width: Int, height: Int) {
        let width = min(max(width, 640), 4096), height = min(max(height, 480), 4096)
        queue.async { [self] in
            guard size != (width, height) else { return }
            size = (width, height)
            displayChanged = true
            device?.update(VZVirtioDeviceSpecificConfiguration(configurationData: Self.words(1, 0, 1, 2))) { _ in }
        }
    }

    /// Called on the main queue with each new frame.
    var onFrame: (@Sendable (VirglFrame) -> Void)? {
        get { frames.withLock { frameHandler } }
        set { frames.withLock { frameHandler = newValue } }
    }
    var lastFrame: VirglFrame? { frames.withLock { latest } }

    func configuration() -> VZCustomVirtioDeviceConfiguration {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = 16
        configuration.pciClassID = 0x03
        configuration.pciSubclassID = 0x80
        configuration.virtioQueueCount = 2
        configuration.optionalFeatures.subset0 = 1 // VIRTIO_GPU_F_VIRGL
        // struct virtio_gpu_config: events_read, events_clear, num_scanouts, num_capsets.
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: Self.words(0, 0, 1, 2))
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: queue, delegate: self)
        return configuration
    }

    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        self.device = device
        device.delegate = self
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        log.info("3D driver up, features \(device.negotiatedFeatures?.subset0 ?? 0, privacy: .public)")
        guard Virgl.shared?.start(fence: { [weak self] fence in self?.signalled = max(self?.signalled ?? 0, Int32(bitPattern: fence)) }) == true else {
            log.error("virglrenderer did not start")
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        // Flushes come in bursts; the screen is read back at most 60 times a second.
        let frameTimer = DispatchSource.makeTimerSource(queue: queue)
        frameTimer.schedule(deadline: .now(), repeating: .milliseconds(16))
        frameTimer.setEventHandler { [weak self] in self?.present() }
        frameTimer.resume()
        self.frameTimer = frameTimer
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) { reset() }
    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) { reset() }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        Virgl.shared?.restoreCurrent()
        while let element = queue.nextElement() {
            if queue.queueIndex == 0, let reply = control(element) {
                pending.append(reply)
            } else if queue.queueIndex == 1 {
                cursor(element)
                element.returnToQueue()
            } else {
                element.returnToQueue()
            }
        }
    }

    private func reset() {
        timer?.cancel(); timer = nil
        frameTimer?.cancel(); frameTimer = nil
        scanout = 0
        dirty = false
        Virgl.shared?.restoreCurrent()
        for id in contexts { Virgl.shared?.contextDestroy(id) }
        for id in Array(backings.keys) { release(id) }
        contexts = []
        pending = []
        log.info("3D device reset after \(self.commands) commands, \(self.submitted) submits")
    }

    private func poll() {
        guard !pending.isEmpty, let virgl = Virgl.shared else { return }
        virgl.restoreCurrent()
        virgl.poll()
        while let first = pending.first, first.fence <= signalled {
            try? first.element.write(first.reply)
            first.element.returnToQueue()
            pending.removeFirst()
        }
    }

    /// The cursor queue: UPDATE_CURSOR carries the pointer image as a resource; MOVE_CURSOR only its position,
    /// which the Mac pointer already shows.
    private func cursor(_ element: VZVirtioQueueElement) {
        guard let request = try? element.readBytes(withExactLength: element.readBuffersAvailableByteCount), request.count >= 52 else { return }
        func u32(_ offset: Int) -> UInt32 { request.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        guard u32(0) == 0x0300 else { return } // UPDATE_CURSOR: pos (scanout, x, y, pad), resource, hot x, hot y
        let resource = u32(40), hotSpot = CGPoint(x: Int(u32(44)), y: Int(u32(48)))
        let image = resource == 0 ? nil : Virgl.shared.flatMap { readImage(resource, virgl: $0) }
        let handler = frames.withLock { () -> (@Sendable (CGImage?, CGPoint) -> Void)? in
            cursorFrame = (image, hotSpot)
            return cursorHandler
        }
        if let handler { DispatchQueue.main.async { handler(image, hotSpot) } }
    }

    /// Reads a resource back from the Mac's GPU as an image; the cursor is drawn with alpha.
    private func readImage(_ id: UInt32, virgl: Virgl) -> CGImage? {
        guard let info = virgl.resourceInfo(id) else { return nil }
        let width = Int(info.width), height = Int(info.height)
        guard width > 0, height > 0, width <= 512, height <= 512 else { return nil }
        virgl.restoreCurrent()
        let size = width * height * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        var vector = iovec(iov_base: buffer, iov_len: size)
        var box = VirglBox(x: 0, y: 0, z: 0, w: UInt32(width), h: UInt32(height), d: 1)
        guard virgl.transferRead(id, context: 0, level: 0, stride: UInt32(width * 4), layerStride: 0, box: &box, offset: 0, into: &vector) == 0 else {
            buffer.deallocate()
            return nil
        }
        let data = Data(bytesNoCopy: buffer, count: size, deallocator: .custom { pointer, _ in pointer.deallocate() })
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Copies the scanout into the next surface on the Mac's GPU, or reads it back to the CPU where that cannot be done.
    private(set) var presentTime: Double = 0
    private func present() {
        guard dirty, scanout != 0, let virgl = Virgl.shared, let info = virgl.resourceInfo(scanout) else { return }
        dirty = false
        let started = DispatchTime.now().uptimeNanoseconds
        defer { presentTime += Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
        virgl.restoreCurrent()
        let width = Int(info.width), height = Int(info.height)
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return }
        if info.tex_id != 0, let surface = surface(width: width, height: height),
           virgl.copy(texture: info.tex_id, width: width, height: height, flipped: info.flags & 1 != 0, into: surface) {
            deliver(VirglFrame(surface: surface, image: nil))
            return
        }
        let size = width * height * 4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        var vector = iovec(iov_base: buffer, iov_len: size)
        var box = VirglBox(x: 0, y: 0, z: 0, w: UInt32(width), h: UInt32(height), d: 1)
        guard virgl.transferRead(scanout, context: 0, level: 0, stride: UInt32(width * 4), layerStride: 0, box: &box, offset: 0, into: &vector) == 0 else {
            buffer.deallocate()
            return
        }
        let data = Data(bytesNoCopy: buffer, count: size, deallocator: .custom { pointer, _ in pointer.deallocate() })
        // virgl formats 1/2 are B8G8R8A8/X8 and 3/4 A8R8G8B8/X8R8G8B8 in memory order; 67/68 R8G8B8A8/X8B8G8R8.
        let order: CGBitmapInfo
        switch info.virgl_format {
        case 67, 68, 134: order = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        case 3, 4: order = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        default: order = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: order, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        deliver(VirglFrame(surface: nil, image: image))
    }

    private func deliver(_ frame: VirglFrame) {
        presented += 1
        let handler = frames.withLock { () -> (@Sendable (VirglFrame) -> Void)? in
            latest = frame
            return frameHandler
        }
        if let handler { DispatchQueue.main.async { handler(frame) } }
    }

    private func surface(width: Int, height: Int) -> IOSurface? {
        if surfaces.first.map({ $0.width != width || $0.height != height }) ?? true {
            surfaces = (0..<3).compactMap { _ in
                IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                       .pixelFormat: kCVPixelFormatType_32BGRA])
            }
            Virgl.shared?.forgetSurfaces()
        }
        guard surfaces.count == 3 else { return nil }
        defer { nextSurface = (nextSurface + 1) % 3 }
        return surfaces[nextSurface % 3]
    }

    private func release(_ id: UInt32) {
        guard let backing = backings.removeValue(forKey: id) else { return }
        Virgl.shared?.detachBacking(id)
        backing.iovecs.deallocate()
        _ = backing.mappings
    }

    /// Handles one control command. Returns the reply to hold back when the guest asked for a fence.
    private func control(_ element: VZVirtioQueueElement) -> (fence: Int32, element: VZVirtioQueueElement, reply: Data)? {
        guard let virgl = Virgl.shared,
              let request = try? element.readBytes(withExactLength: element.readBuffersAvailableByteCount), request.count >= 24 else {
            return nil
        }
        commands += 1
        func u32(_ offset: Int) -> UInt32 { request.count >= offset + 4 ? request.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } : 0 }
        func u64(_ offset: Int) -> UInt64 { request.count >= offset + 8 ? request.subdata(in: offset..<offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } : 0 }
        let context = u32(16)
        var body = Data()
        var reply: UInt32 = 0x1100 // OK_NODATA
        func check(_ result: Int32) { if result != 0 { reply = 0x1200 } }
        switch u32(0) {
        case 0x0100: // GET_DISPLAY_INFO: one enabled screen
            reply = 0x1101
            body = Self.words(0, 0, UInt32(size.width), UInt32(size.height), 1, 0) + Data(count: 15 * 24)
            if displayChanged {
                displayChanged = false
                device?.update(VZVirtioDeviceSpecificConfiguration(configurationData: Self.words(0, 0, 1, 2))) { _ in }
            }
        case 0x0108: // GET_CAPSET_INFO: index
            let id = u32(24) + 1
            let (version, size) = virgl.capset(id)
            reply = 0x1102
            body = Self.words(id, version, size, 0)
        case 0x0109: // GET_CAPSET: id, version
            reply = 0x1103
            body = virgl.caps(u32(24), version: u32(28))
        case 0x0101: // RESOURCE_CREATE_2D: id, format, width, height
            var args = VirglResourceArgs(handle: u32(24), target: 2, format: u32(28), bind: 1 << 1, width: u32(32), height: u32(36),
                                         depth: 1, array_size: 1, last_level: 0, nr_samples: 0, flags: 1)
            check(virgl.resourceCreate(&args))
        case 0x0204: // RESOURCE_CREATE_3D
            var args = VirglResourceArgs(handle: u32(24), target: u32(28), format: u32(32), bind: u32(36), width: u32(40), height: u32(44),
                                         depth: u32(48), array_size: u32(52), last_level: u32(56), nr_samples: u32(60), flags: u32(64))
            check(virgl.resourceCreate(&args))
        case 0x0102: // RESOURCE_UNREF
            release(u32(24))
            virgl.resourceUnref(u32(24))
        case 0x0106: // RESOURCE_ATTACH_BACKING: id, entries, then { address u64, length u32, padding u32 }
            let id = u32(24), count = Int(u32(28))
            var mappings: [VZGuestMemoryMapping] = []
            for index in 0..<min(count, 65_536) where 32 + index * 16 + 16 <= request.count {
                if let mapping = device?.guestMemoryMapping(atPhysicalAddress: u64(32 + index * 16), length: Int(u32(40 + index * 16))) {
                    mappings.append(mapping)
                }
            }
            release(id)
            let iovecs = UnsafeMutablePointer<iovec>.allocate(capacity: max(mappings.count, 1))
            for (index, mapping) in mappings.enumerated() { iovecs[index] = iovec(iov_base: mapping.mutableBytes, iov_len: mapping.length) }
            backings[id] = Backing(mappings: mappings, iovecs: iovecs)
            check(virgl.attachBacking(id, iovecs, Int32(mappings.count)))
        case 0x0107: // RESOURCE_DETACH_BACKING
            release(u32(24))
        case 0x0103: // SET_SCANOUT: rect, scanout id, resource id
            scanout = u32(44)
            dirty = scanout != 0
        case 0x0104: // RESOURCE_FLUSH: rect, resource id
            if u32(40) == scanout { dirty = true }
        case 0x0105: // TRANSFER_TO_HOST_2D: rect, offset, resource id
            var box = VirglBox(x: u32(24), y: u32(28), z: 0, w: u32(32), h: u32(36), d: 1)
            check(virgl.transferWrite(u32(48), context: 0, level: 0, stride: 0, layerStride: 0, box: &box, offset: u64(40)))
        case 0x0200: // CTX_CREATE: name length, context_init, name
            let length = min(u32(24), 64)
            let name = request.count >= 32 + Int(length) ? Array(request[32..<32 + Int(length)]) + [0] : [0]
            check(virgl.contextCreate(context, name: name))
            contexts.insert(context)
        case 0x0201: // CTX_DESTROY
            virgl.contextDestroy(context)
            contexts.remove(context)
        case 0x0202: // CTX_ATTACH_RESOURCE
            virgl.contextAttach(context, u32(24))
        case 0x0203: // CTX_DETACH_RESOURCE
            virgl.contextDetach(context, u32(24))
        case 0x0205, 0x0206: // TRANSFER_TO/FROM_HOST_3D: box, offset, resource id, level, stride, layer stride
            var box = VirglBox(x: u32(24), y: u32(28), z: u32(32), w: u32(36), h: u32(40), d: u32(44))
            if u32(0) == 0x0205 {
                check(virgl.transferWrite(u32(56), context: context, level: u32(60), stride: u32(64), layerStride: u32(68), box: &box, offset: u64(48)))
            } else {
                check(virgl.transferRead(u32(56), context: context, level: u32(60), stride: u32(64), layerStride: u32(68), box: &box, offset: u64(48)))
            }
        case 0x0207: // SUBMIT_3D: size, padding, commands
            let size = Int(u32(24))
            guard request.count >= 32 + size, size % 4 == 0 else { reply = 0x1200; break }
            submitted += 1
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(size, 8), alignment: 8)
            defer { buffer.deallocate() }
            request.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: 32..<32 + size)
            check(virgl.submit(buffer, context: context, words: Int32(size / 4)))
        default:
            log.error("unhandled 3D command \(String(u32(0), radix: 16), privacy: .public)")
            reply = 0x1200 // ERR_UNSPEC
        }
        let fenced = u32(4) & 1 != 0
        var header = Self.words(reply, u32(4) & 1)
        header.append(request.subdata(in: 8..<24))
        guard fenced else {
            try? element.write(header + body)
            return nil
        }
        nextFence &+= 1
        virgl.createFence(nextFence, context: context)
        return (nextFence, element, header + body)
    }

    private static func words(_ values: UInt32...) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }
}

/// A screen frame: an IOSurface the Mac GPU copied the guest's screen into, or, without that, an image read back to the CPU.
struct VirglFrame: @unchecked Sendable {
    let surface: IOSurface?
    let image: CGImage?
    var width: Int { surface?.width ?? image?.width ?? 0 }
    var height: Int { surface?.height ?? image?.height ?? 0 }
    /// An image of the frame, for checks; the view shows the surface itself.
    func cgImage() -> CGImage? {
        if let image { return image }
        guard let surface else { return nil }
        // Row 0 of the surface is the top of the screen, as the layer shows it.
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: surface.bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct VirglResourceArgs {
    var handle, target, format, bind, width, height, depth, array_size, last_level, nr_samples, flags: UInt32
}

struct VirglResourceInfo {
    var handle, virgl_format, width, height, depth, flags, tex_id, stride: UInt32
    var drm_fourcc: Int32, fd: Int32
}

struct VirglBox {
    var x, y, z, w, h, d: UInt32
}

private struct VirglCallbacks {
    var version: Int32
    var writeFence: (@convention(c) (UnsafeMutableRawPointer?, UInt32) -> Void)?
    var createContext: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?)?
    var destroyContext: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?
    var makeCurrent: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32)?
}

/// virglrenderer, loaded from the app's Frameworks, on Apple's OpenGL 4.1 core contexts: a Linux guest gets OpenGL 4.1.
/// ANGLE's Metal backend offers only GL ES 3.0, which leaves a Linux guest at OpenGL 2.1. Every call happens on the
/// device queue; its threads change, so each entry first restores the context virglrenderer last made current.
final class Virgl: @unchecked Sendable {
    static let shared: Virgl? = Virgl()

    private let library: UnsafeMutableRawPointer
    private var started = false
    private var current: UnsafeMutableRawPointer?
    private var fence: ((UInt32) -> Void)?
    private var callbacks = VirglCallbacks(version: 1)

    private init?() {
        guard let frameworks = Bundle.main.privateFrameworksPath,
              let library = dlopen(frameworks + "/libvirglrenderer.1.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        self.library = library
    }

    private static func makeCGLContext(shared: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        let attributes: [CGLPixelFormatAttribute] = [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_GL4_Core.rawValue)),
                                                     kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers, CGLPixelFormatAttribute(0)]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        guard CGLChoosePixelFormat(attributes, &format, &count) == kCGLNoError, let format else { return nil }
        defer { CGLReleasePixelFormat(format) }
        var context: CGLContextObj?
        CGLCreateContext(format, shared?.assumingMemoryBound(to: _CGLContextObject.self), &context)
        return context.map { UnsafeMutableRawPointer($0) }
    }

    private func symbol<T>(_ name: String, as type: T.Type) -> T {
        unsafeBitCast(dlsym(library, name)!, to: type)
    }

    func start(fence: @escaping (UInt32) -> Void) -> Bool {
        self.fence = fence
        if started { return true }
        callbacks.writeFence = { cookie, id in Unmanaged<Virgl>.fromOpaque(cookie!).takeUnretainedValue().fence?(id) }
        callbacks.createContext = { cookie, _, param in
            let virgl = Unmanaged<Virgl>.fromOpaque(cookie!).takeUnretainedValue()
            // struct virgl_renderer_gl_ctx_param: int version, bool shared, ... "Shared" means with the current context.
            guard let param else { return nil }
            let shared = param.load(fromByteOffset: 4, as: Bool.self)
            return Virgl.makeCGLContext(shared: shared ? virgl.current : nil)
        }
        callbacks.destroyContext = { _, context in
            if let context { CGLDestroyContext(context.assumingMemoryBound(to: _CGLContextObject.self)) }
        }
        callbacks.makeCurrent = { cookie, _, context in
            let virgl = Unmanaged<Virgl>.fromOpaque(cookie!).takeUnretainedValue()
            virgl.current = context
            virgl.makeCurrent(context)
            return 0
        }
        // Without an EGL display, virglrenderer takes contexts from the callbacks only; it starts on a current one.
        current = Self.makeCGLContext(shared: nil)
        makeCurrent(current)
        let initialize = symbol("virgl_renderer_init", as: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer) -> Int32).self)
        let result = withUnsafeMutablePointer(to: &callbacks) { initialize(Unmanaged.passUnretained(self).toOpaque(), 0, $0) }
        log.info("virglrenderer init \(result)")
        started = result == 0
        return started
    }

    private func makeCurrent(_ context: UnsafeMutableRawPointer?) {
        CGLSetCurrentContext(context?.assumingMemoryBound(to: _CGLContextObject.self))
    }

    func restoreCurrent() { if started { makeCurrent(current) } }

    /// The copy into surfaces runs in its own context, in virglrenderer's share group, so it sees the guest's textures.
    private var copyContext: UnsafeMutableRawPointer?
    private var copyFramebuffers: [GLuint] = [0, 0]
    private var surfaceTextures: [ObjectIdentifier: GLuint] = [:]

    func forgetSurfaces() {
        guard let copyContext, !surfaceTextures.isEmpty else { return }
        CGLSetCurrentContext(copyContext.assumingMemoryBound(to: _CGLContextObject.self))
        var textures = Array(surfaceTextures.values)
        glDeleteTextures(GLsizei(textures.count), &textures)
        surfaceTextures = [:]
        restoreCurrent()
    }

    /// Copies a guest texture into `surface` on the Mac's GPU. Scanouts already keep their top row first; only a
    /// resource marked "row 0 at the top" is stored turned over by virglrenderer, and is turned back.
    /// Returns false where the copy cannot be made.
    func copy(texture: UInt32, width: Int, height: Int, flipped: Bool, into surface: IOSurface) -> Bool {
        guard started, let current else { return false }
        if copyContext == nil {
            copyContext = Self.makeCGLContext(shared: current)
            guard let copyContext else { return false }
            CGLSetCurrentContext(copyContext.assumingMemoryBound(to: _CGLContextObject.self))
            glGenFramebuffers(2, &copyFramebuffers)
        }
        guard let copyContext else { return false }
        let context = copyContext.assumingMemoryBound(to: _CGLContextObject.self)
        CGLSetCurrentContext(context)
        defer { restoreCurrent() }
        let key = ObjectIdentifier(surface)
        if surfaceTextures[key] == nil {
            var name: GLuint = 0
            glGenTextures(1, &name)
            glBindTexture(GLenum(GL_TEXTURE_RECTANGLE), name)
            let result = CGLTexImageIOSurface2D(context, GLenum(GL_TEXTURE_RECTANGLE), GLenum(GL_RGBA), GLsizei(width), GLsizei(height),
                                                GLenum(GL_BGRA), GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
                                                unsafeBitCast(surface, to: IOSurfaceRef.self), 0)
            guard result == kCGLNoError else { glDeleteTextures(1, &name); return false }
            surfaceTextures[key] = name
        }
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), copyFramebuffers[0])
        glFramebufferTexture2D(GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), copyFramebuffers[1])
        glFramebufferTexture2D(GLenum(GL_DRAW_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_RECTANGLE), surfaceTextures[key]!, 0)
        guard glCheckFramebufferStatus(GLenum(GL_READ_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE),
              glCheckFramebufferStatus(GLenum(GL_DRAW_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { return false }
        let w = GLint(width), h = GLint(height)
        glBlitFramebuffer(0, 0, w, h, 0, flipped ? h : 0, w, flipped ? 0 : h, GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glFlush()
        return true
    }

    func poll() { symbol("virgl_renderer_poll", as: (@convention(c) () -> Void).self)() }

    func capset(_ id: UInt32) -> (UInt32, UInt32) {
        var version: UInt32 = 0, size: UInt32 = 0
        symbol("virgl_renderer_get_cap_set", as: (@convention(c) (UInt32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Void).self)(id, &version, &size)
        return (version, size)
    }

    func caps(_ id: UInt32, version: UInt32) -> Data {
        let (_, size) = capset(id)
        var data = Data(count: Int(size))
        data.withUnsafeMutableBytes {
            symbol("virgl_renderer_fill_caps", as: (@convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?) -> Void).self)(id, version, $0.baseAddress)
        }
        return data
    }

    func resourceCreate(_ args: inout VirglResourceArgs) -> Int32 {
        symbol("virgl_renderer_resource_create", as: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?, UInt32) -> Int32).self)(&args, nil, 0)
    }

    func resourceUnref(_ id: UInt32) {
        symbol("virgl_renderer_resource_unref", as: (@convention(c) (UInt32) -> Void).self)(id)
    }

    func attachBacking(_ id: UInt32, _ iovecs: UnsafeMutablePointer<iovec>, _ count: Int32) -> Int32 {
        symbol("virgl_renderer_resource_attach_iov", as: (@convention(c) (Int32, UnsafeMutablePointer<iovec>, Int32) -> Int32).self)(Int32(bitPattern: id), iovecs, count)
    }

    func detachBacking(_ id: UInt32) {
        symbol("virgl_renderer_resource_detach_iov", as: (@convention(c) (Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self)(Int32(bitPattern: id), nil, nil)
    }

    func transferWrite(_ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: inout VirglBox, offset: UInt64) -> Int32 {
        symbol("virgl_renderer_transfer_write_iov", as: (@convention(c) (UInt32, UInt32, Int32, UInt32, UInt32, UnsafeMutableRawPointer, UInt64, UnsafeMutableRawPointer?, UInt32) -> Int32).self)(
            id, context, Int32(bitPattern: level), stride, layerStride, &box, offset, nil, 0)
    }

    func transferRead(_ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: inout VirglBox, offset: UInt64) -> Int32 {
        symbol("virgl_renderer_transfer_read_iov", as: (@convention(c) (UInt32, UInt32, UInt32, UInt32, UInt32, UnsafeMutableRawPointer, UInt64, UnsafeMutableRawPointer?, Int32) -> Int32).self)(
            id, context, level, stride, layerStride, &box, offset, nil, 0)
    }

    func resourceInfo(_ id: UInt32) -> VirglResourceInfo? {
        var info = VirglResourceInfo(handle: 0, virgl_format: 0, width: 0, height: 0, depth: 0, flags: 0, tex_id: 0, stride: 0, drm_fourcc: 0, fd: -1)
        let result = symbol("virgl_renderer_resource_get_info", as: (@convention(c) (Int32, UnsafeMutableRawPointer) -> Int32).self)(Int32(bitPattern: id), &info)
        return result == 0 ? info : nil
    }

    func transferRead(_ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: inout VirglBox, offset: UInt64,
                      into vector: inout iovec) -> Int32 {
        symbol("virgl_renderer_transfer_read_iov", as: (@convention(c) (UInt32, UInt32, UInt32, UInt32, UInt32, UnsafeMutableRawPointer, UInt64, UnsafeMutableRawPointer?, Int32) -> Int32).self)(
            id, context, level, stride, layerStride, &box, offset, &vector, 1)
    }

    func contextCreate(_ id: UInt32, name: [UInt8]) -> Int32 {
        name.withUnsafeBufferPointer {
            symbol("virgl_renderer_context_create", as: (@convention(c) (UInt32, UInt32, UnsafePointer<UInt8>?) -> Int32).self)(id, UInt32(name.count - 1), $0.baseAddress)
        }
    }

    func contextDestroy(_ id: UInt32) {
        symbol("virgl_renderer_context_destroy", as: (@convention(c) (UInt32) -> Void).self)(id)
    }

    func contextAttach(_ context: UInt32, _ id: UInt32) {
        symbol("virgl_renderer_ctx_attach_resource", as: (@convention(c) (Int32, Int32) -> Void).self)(Int32(bitPattern: context), Int32(bitPattern: id))
    }

    func contextDetach(_ context: UInt32, _ id: UInt32) {
        symbol("virgl_renderer_ctx_detach_resource", as: (@convention(c) (Int32, Int32) -> Void).self)(Int32(bitPattern: context), Int32(bitPattern: id))
    }

    func submit(_ buffer: UnsafeMutableRawPointer, context: UInt32, words: Int32) -> Int32 {
        symbol("virgl_renderer_submit_cmd", as: (@convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32).self)(buffer, Int32(bitPattern: context), words)
    }

    func createFence(_ fence: Int32, context: UInt32) {
        _ = symbol("virgl_renderer_create_fence", as: (@convention(c) (Int32, UInt32) -> Int32).self)(fence, context)
    }
}

/// The desktop's frames, with the Mac's mouse and keyboard going to VZ's USB devices as for Windows.
@available(macOS 27, *)
struct VirglDisplay: NSViewRepresentable {
    let gpu: VirglGPU
    let machine: VZVirtualMachine
    let queue: DispatchQueue
    var resizes = false
    var native: NativeDisplay?
    func makeNSView(context: Context) -> VirglScreenView {
        let view = VirglScreenView(gpu: gpu, machine: machine, queue: queue)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: VirglScreenView, context: Context) {
        view.native = native
        view.resizes = resizes
    }
}

@available(macOS 27, *)
final class VirglScreenView: NSView, DesktopDisplayView {
    private let machine: VZVirtualMachine
    /// The VM runs on Containerization's queue and takes calls only there.
    private let queue: DispatchQueue
    private let gpu: VirglGPU
    private var imageSize = CGSize(width: VirglGPU.screen.width, height: VirglGPU.screen.height)
    private var buttons: UInt = 0
    private var cursor = NSCursor.arrow
    var native: NativeDisplay?
    var resizes = false { didSet { if resizes != oldValue { applySize() } } }
    var pasteboard = NSPasteboard.general
    var displayedMachine: VZVirtualMachine? { machine }
    var followsWindowSize: Bool { resizes }

    init(gpu: VirglGPU, machine: VZVirtualMachine, queue: DispatchQueue) {
        self.machine = machine
        self.queue = queue
        self.gpu = gpu
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        screen.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        // The guest's X channel is not alpha.
        screen.isOpaque = true
        layer?.addSublayer(screen)
        gpu.onFrame = { [weak self] frame in MainActor.assumeIsolated { self?.show(frame) } }
        gpu.onCursor = { [weak self] image, hotSpot in MainActor.assumeIsolated { self?.setCursor(image, hotSpot: hotSpot) } }
        if let frame = gpu.lastFrame { show(frame) }
        if let (image, hotSpot) = gpu.lastCursor { setCursor(image, hotSpot: hotSpot) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applySize()
        layoutScreen()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySize()
    }
    /// The screen follows the view's size in pixels while the setting is on, and is 1920 by 1200 otherwise.
    private func applySize() {
        let scale = window?.backingScaleFactor ?? 1
        native?.apply(resizes: resizes, viewPixels: CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }

    /// The guest's own pointer becomes the Mac pointer over the screen, scaled as the screen is.
    private func setCursor(_ image: CGImage?, hotSpot: CGPoint) {
        guard let image else {
            cursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
            window?.invalidateCursorRects(for: self)
            return
        }
        let scale = displayScale
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        cursor = NSCursor(image: NSImage(cgImage: image, size: size), hotSpot: NSPoint(x: hotSpot.x * scale, y: hotSpot.y * scale))
        window?.invalidateCursorRects(for: self)
        if let window, window.isKeyWindow, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { cursor.set() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    // ⌘C and ⌘V, and Copy and Paste in the Edit menu, copy and paste between the Mac and the guest.
    @objc func copy(_ sender: Any?) { transfer(copying: true) }
    @objc func paste(_ sender: Any?) { transfer(copying: false) }
    private func clipboardKey(_ event: NSEvent) -> Bool? {
        guard native != nil, event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return true
        case "v": return false
        default: return nil
        }
    }
    private func transfer(copying: Bool) {
        guard let native else { return }
        let pasteboard = pasteboard
        Task { @MainActor in
            if !copying {
                guard let text = pasteboard.string(forType: .string) else { return }
                try? await native.surface.paste(text)
            } else if let text = try? await native.surface.copy(), !text.isEmpty {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }
    required init?(coder: NSCoder) { nil }

    private func show(_ frame: VirglFrame) {
        imageSize = CGSize(width: frame.width, height: frame.height)
        // Guest pixels go to the display as they are, as VZ's own view shows them, rather than converted from sRGB.
        let space = window?.colorSpace?.cgColorSpace
        if let surface = frame.surface {
            if let space, let profile = space.copyICCData() {
                IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, profile)
            }
            screen.contents = surface
        } else if let image = frame.image {
            screen.contents = space.flatMap { image.copy(colorSpace: $0) } ?? image
        }
        layoutScreen()
    }
    /// The frame's points on screen: pixel for pixel when it fits, so it stays sharp, else scaled down to fit.
    private var displayScale: CGFloat {
        let pixels = window?.backingScaleFactor ?? 1
        let fitted = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return min(fitted, 1 / pixels)
    }
    /// Where the frame sits in the view: centred, on whole device pixels, so nothing is resampled at 1:1.
    private var screenRect: CGRect {
        let pixels = window?.backingScaleFactor ?? 1
        let scale = displayScale
        let width = imageSize.width * scale, height = imageSize.height * scale
        let x = ((bounds.width - width) / 2 * pixels).rounded(.down) / pixels
        let y = ((bounds.height - height) / 2 * pixels).rounded(.down) / pixels
        return CGRect(x: x, y: y, width: width, height: height)
    }
    private let screen = CALayer()
    #if NOODLE_DEV_HOOKS
    var probeDescription: String {
        "view \(bounds.size) frame \(imageSize) layer \(screen.frame) filter \(screen.magnificationFilter.rawValue)"
    }
    #endif
    private func layoutScreen() {
        let pixels = window?.backingScaleFactor ?? 1
        screen.frame = screenRect
        screen.contentsScale = pixels
        let exact = displayScale * pixels >= 1
        screen.magnificationFilter = exact ? .nearest : .linear
        screen.minificationFilter = exact ? .nearest : .trilinear
    }
    override func layout() {
        super.layout()
        layoutScreen()
    }

    override var acceptsFirstResponder: Bool { true }
    // Drags belong to the guest, not to moving the window, and the first click already reaches it.
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    private func location(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = screenRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let x = (point.x - rect.minX) / rect.width
        let y = 1 - (point.y - rect.minY) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
    private func send(_ action: @escaping @Sendable (VZVirtualMachine) -> Void) {
        nonisolated(unsafe) let machine = machine
        queue.async { if machine.state == .running { action(machine) } }
    }
    private func pointer(_ event: NSEvent) {
        let location = location(event), buttons = buttons
        send { WindowsPrivateVirtualization.pointer($0, at: location, buttons: buttons) }
    }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(event) }
    override func mouseUp(with event: NSEvent) { buttons &= ~1; pointer(event) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 2; pointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~2; pointer(event) }
    override func scrollWheel(with event: NSEvent) {
        nonisolated(unsafe) let event = event
        send { WindowsPrivateVirtualization.scroll($0, event) }
    }
    private func key(_ event: NSEvent) {
        nonisolated(unsafe) let event = event
        send { WindowsPrivateVirtualization.key($0, event) }
    }
    override func keyDown(with event: NSEvent) {
        if let copying = clipboardKey(event) { transfer(copying: copying) } else { key(event) }
    }
    override func keyUp(with event: NSEvent) { key(event) }
    override func flagsChanged(with event: NSEvent) { key(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if let copying = clipboardKey(event) { transfer(copying: copying) } else { key(event) }
        return true
    }
}

#if NOODLE_DEV_HOOKS
/// Development harness (`--virgl-test`): keeps one desktop between runs, so packages installed in it stay, starts it,
/// runs the base64 script in the `VirglScript` default and prints its output.
@MainActor
enum VirglCheck {
    /// With `VirglInteractive`, the spike desktop is started and left open in the library window to use by hand.
    static var isInteractive: Bool { UserDefaults.standard.bool(forKey: "VirglInteractive") }

    static func interactive() async throws -> ComputerStore {
        let store = try ComputerStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("NoodleVirgl-Spike"))
        guard let session = store.sessions.first else { throw ComputerError("Run --virgl-test once first to create the desktop.") }
        store.selection = session.id
        Task { await store.start(session) }
        return store
    }

    static func run() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleVirgl-Spike")
        let store = try ComputerStore(root: root)
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                if let status = store.creationStatus { print("VIRGL: \(status) \(store.creationDetail ?? "")") }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        defer { monitor.cancel() }
        if store.sessions.isEmpty {
            guard await store.create(ComputerTemplate.desktop.makeComputer(name: "Virgl Spike"), source: nil) else {
                throw ComputerError(store.error ?? "Desktop creation failed.")
            }
        }
        guard let session = store.sessions.first else { throw ComputerError("No desktop.") }
        await store.start(session)
        guard session.phase == .running else { throw ComputerError("Desktop startup failed: \(session.console)") }
        print("VIRGL: running")
        let script = UserDefaults.standard.string(forKey: "VirglScript").flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "ls -l /dev/dri"
        for part in script.components(separatedBy: "\n#--\n") {
            session.console = ""
            await store.execute(part, in: session)
            print("VIRGL OUTPUT BEGIN\n\(session.console)\nVIRGL OUTPUT END")
        }
        if UserDefaults.standard.bool(forKey: "VirglInputProbe"), #available(macOS 27, *), let gpu = session.display?.virgl,
           let machine = session.display?.machine, let queue = session.display?.machineQueue {
            // Mouse, scroll and keys through the view, as a person's would arrive.
            let view = VirglScreenView(gpu: gpu, machine: machine, queue: queue)
            view.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            for step in 0..<40 {
                let point = NSPoint(x: 100 + step * 10, y: 300)
                if let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { view.mouseMoved(with: move) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) { view.keyDown(with: key) }
            for units in [CGScrollEventUnit.line, .pixel] {
                for _ in 0..<5 {
                    if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: units == .line ? -3 : -40, wheel2: 0, wheel3: 0),
                       let event = NSEvent(cgEvent: scroll) {
                        view.scrollWheel(with: event)
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            if UserDefaults.standard.bool(forKey: "VirglProbeMainThread") {
                print("VIRGL INPUT PROBE: pointer from the main thread, as before the fix")
                WindowsPrivateVirtualization.pointer(machine, at: CGPoint(x: 0.5, y: 0.5), buttons: 0)
            }
            try? await Task.sleep(for: .seconds(1))
            print("VIRGL INPUT PROBE SURVIVED")
        }
        if UserDefaults.standard.bool(forKey: "VirglSharpProbe"), #available(macOS 27, *), let gpu = session.display?.virgl,
           let machine = session.display?.machine, let queue = session.display?.machineQueue {
            let view = VirglScreenView(gpu: gpu, machine: machine, queue: queue)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.native = session.display
            view.resizes = true
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .seconds(8))
            view.layoutSubtreeIfNeeded()
            print("VIRGL SHARP \(view.probeDescription) backing \(window.backingScaleFactor) colour \(window.colorSpace?.localizedName ?? "none")")
        }
        if UserDefaults.standard.bool(forKey: "VirglCtrlC"), let machine = session.display?.machine, let queue = session.display?.machineQueue {
            // Control down, C down and up, control up, through VZ's USB keyboard as a person's keys arrive.
            func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String) {
                let event: NSEvent? = type == .flagsChanged
                    ? NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
                    : NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                       characters: characters, charactersIgnoringModifiers: "c", isARepeat: false, keyCode: code)
                guard let event else { return }
                nonisolated(unsafe) let sent = event
                nonisolated(unsafe) let vm = machine
                queue.sync { WindowsPrivateVirtualization.key(vm, sent) }
            }
            key(.flagsChanged, 59, .control, "")
            key(.keyDown, 8, .control, "\u{3}")
            key(.keyUp, 8, .control, "\u{3}")
            key(.flagsChanged, 59, [], "")
            print("VIRGL CTRL-C SENT")
            try? await Task.sleep(for: .seconds(4))
        }
        if UserDefaults.standard.bool(forKey: "VirglResizeCycle"), #available(macOS 27, *), let gpu = session.display?.virgl {
            for (index, size) in [(1200, 800), (1513, 911), (1101, 707), (1920, 1200), (1333, 977), (1700, 1000)].enumerated() {
                gpu.resize(width: size.0, height: size.1)
                try? await Task.sleep(for: .seconds(4))
                print("VIRGL CYCLE \(index) asked \(size.0)x\(size.1) got \(gpu.lastFrame.map { "\($0.width)x\($0.height)" } ?? "none")")
            }
        }
        if UserDefaults.standard.bool(forKey: "VirglResizeProbe"), #available(macOS 27, *), let gpu = session.display?.virgl {
            print("VIRGL CURSOR \(gpu.lastCursor.map { "\($0.0.map { "\($0.width)x\($0.height)" } ?? "hidden") hot \($0.1)" } ?? "none")")
            gpu.resize(width: 1280, height: 800)
            try? await Task.sleep(for: .seconds(8))
            print("VIRGL RESIZED FRAME \(gpu.lastFrame.map { "\($0.width)x\($0.height)" } ?? "none")")
        }
        if let after = UserDefaults.standard.string(forKey: "VirglAfterScript").flatMap({ Data(base64Encoded: $0) }).flatMap({ String(data: $0, encoding: .utf8) }) {
            session.console = ""
            await store.execute(after, in: session)
            print("VIRGL OUTPUT BEGIN\n\(session.console)\nVIRGL OUTPUT END")
        }
        if #available(macOS 27, *), let gpu = session.display?.virgl, let frame = gpu.lastFrame, let image = frame.cgImage(),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            print("VIRGL FRAMES \(gpu.presented) via \(frame.surface == nil ? "CPU readback" : "IOSurface"), \(String(format: "%.2f", gpu.presentTime / Double(max(gpu.presented, 1)))) ms each on the device queue")
            print("VIRGL SCREEN \(png.base64EncodedString())")
        }
        await store.stop(session, force: !UserDefaults.standard.bool(forKey: "VirglGentleStop"))
    }
}
#endif
