import Darwin
import Foundation
import os

private let log = Logger(subsystem: "com.pdparchitect.noodle.computer", category: "WindowsRenderer")

struct VirglResourceArgs { var handle, target, format, bind, width, height, depth, array_size, last_level, nr_samples, flags: UInt32 }
struct VirglBox { var x, y, z, w, h, d: UInt32 }

private struct NeptuneCallbacks {
    var version: Int32
    var writeFence: (@convention(c) (UnsafeMutableRawPointer?, UInt32) -> Void)?
    var createContext: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?)?
    var destroyContext: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?
    var makeCurrent: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32)?
    var getDRMFD: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?
    var writeContextFence: (@convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UInt64) -> Void)?
    var getServerFD: (@convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int32)?
    var getEGLDisplay: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?)?
}

private struct BlobArgs {
    var handle, context, memory, flags: UInt32
    var blob, size: UInt64
    var iovecs: UnsafePointer<iovec>?
    var count: UInt32
}

struct RendererLocation {
    let group: String
    let frameworks: String
    init(executable: URL) throws {
        let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Bundle aliases the enclosing app to this executable's embedded Info.plist.
        // Read the parent's metadata explicitly; the helper keeps LSBackgroundOnly.
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")), format: nil)
        guard let group = (info as? [String: Any])?["NoodleGPUGroup"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        self.group = group
        frameworks = appURL.appendingPathComponent("Contents/Frameworks/neptune").path
    }
}

/// virglrenderer built with Neptune, on ANGLE's GL ES over Metal, with DXMT for Direct3D 10 and 11. The render
/// server runs in this per-VM helper (thread mode), which inherits the app sandbox.
final class NativeNeptuneLibrary: @unchecked Sendable {
    static let shared: NativeNeptuneLibrary? = NativeNeptuneLibrary()

    private let library: UnsafeMutableRawPointer
    private let egl: UnsafeMutableRawPointer
    private let display: UnsafeMutableRawPointer
    private var started = false
    private var current: UnsafeMutableRawPointer?
    private var fence: ((UInt32, UInt32?, UInt64) -> Void)?
    private var callbacks = NeptuneCallbacks(version: 4)

    private init?() {
        let location: RendererLocation
        do { location = try RendererLocation(executable: URL(fileURLWithPath: CommandLine.arguments[0])) }
        catch { log.error("Reading the renderer installation failed: \(error.localizedDescription, privacy: .public)"); return nil }
        let group = location.group, frameworks = location.frameworks
        let dxmt = frameworks + "/libdxmt-native.dylib"
        setenv("NPT_BACKEND", "dxmt", 1)
        for name in ["NPT_D3D11_LIBRARY_PATH", "NPT_DXGI_LIBRARY_PATH", "NPT_D3D12_LIBRARY_PATH"] { setenv(name, dxmt, 1) }
        // In the sandbox, shared memory names must start with an app group, and fit in 31 characters.
        setenv("APP_SANDBOX_GROUP_ID", group, 1)
        // ANGLE's EGL opens GLESv2.framework by a path relative to the working directory.
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(frameworks)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        guard let egl = dlopen(frameworks + "/EGL.framework/EGL", RTLD_NOW | RTLD_GLOBAL),
              dlopen(frameworks + "/GLESv2.framework/GLESv2", RTLD_NOW | RTLD_GLOBAL) != nil,
              let library = dlopen(frameworks + "/libvirglrenderer-neptune.dylib", RTLD_NOW | RTLD_LOCAL) else {
            log.error("Neptune libraries did not load: \(String(cString: dlerror()), privacy: .public)")
            return nil
        }
        guard dlsym(library, "virgl_renderer_resource_create_blob_at") != nil else {
            log.error("Neptune renderer lacks shared-arena support")
            return nil
        }
        self.egl = egl
        self.library = library
        typealias PlatformDisplay = @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafePointer<Int>?) -> UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> UInt32
        typealias BindAPI = @convention(c) (UInt32) -> UInt32
        guard let platformDisplay = dlsym(egl, "eglGetPlatformDisplay").map({ unsafeBitCast($0, to: PlatformDisplay.self) }),
              let initialize = dlsym(egl, "eglInitialize").map({ unsafeBitCast($0, to: Initialize.self) }),
              let bindAPI = dlsym(egl, "eglBindAPI").map({ unsafeBitCast($0, to: BindAPI.self) }) else { return nil }
        // EGL_PLATFORM_ANGLE_ANGLE with EGL_PLATFORM_ANGLE_TYPE_ANGLE = EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE.
        let attributes: [Int] = [0x3203, 0x3489, 0x3038]
        guard let display = attributes.withUnsafeBufferPointer({ platformDisplay(0x3202, nil, $0.baseAddress) }),
              initialize(display, nil, nil) != 0, bindAPI(0x30A0) != 0 else {
            fputs("Windows renderer EGL initialization failed\n", stderr)
            return nil
        }
        self.display = display
    }

    private func symbol<T>(_ name: String, as type: T.Type) -> T { unsafeBitCast(dlsym(library, name)!, to: type) }
    private func eglSymbol<T>(_ name: String, as type: T.Type) -> T { unsafeBitCast(dlsym(egl, name)!, to: type) }

    func start(fence: @escaping (UInt32, UInt32?, UInt64) -> Void) -> Bool {
        self.fence = fence
        if started { return true }
        callbacks.writeFence = { cookie, id in Unmanaged<NativeNeptuneLibrary>.fromOpaque(cookie!).takeUnretainedValue().fence?(0, nil, UInt64(id)) }
        callbacks.writeContextFence = { cookie, context, ring, id in
            Unmanaged<NativeNeptuneLibrary>.fromOpaque(cookie!).takeUnretainedValue().fence?(context, ring, id)
        }
        callbacks.createContext = { cookie, _, param in
            let neptune = Unmanaged<NativeNeptuneLibrary>.fromOpaque(cookie!).takeUnretainedValue()
            guard let param else { return nil }
            let shared = param.load(fromByteOffset: 4, as: Bool.self)
            let major = param.load(fromByteOffset: 8, as: Int32.self), minor = param.load(fromByteOffset: 12, as: Int32.self)
            let attributes: [Int32] = [0x3098, major, 0x30FB, minor, 0x3038]
            let create = neptune.eglSymbol("eglCreateContext", as: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafePointer<Int32>?) -> UnsafeMutableRawPointer?).self)
            let currentContext = neptune.eglSymbol("eglGetCurrentContext", as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
            return attributes.withUnsafeBufferPointer { create(neptune.display, nil, shared ? currentContext() : nil, $0.baseAddress) }
        }
        callbacks.destroyContext = { cookie, context in
            let neptune = Unmanaged<NativeNeptuneLibrary>.fromOpaque(cookie!).takeUnretainedValue()
            _ = neptune.eglSymbol("eglDestroyContext", as: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UInt32).self)(neptune.display, context)
        }
        callbacks.makeCurrent = { cookie, _, context in
            let neptune = Unmanaged<NativeNeptuneLibrary>.fromOpaque(cookie!).takeUnretainedValue()
            neptune.current = context
            neptune.makeCurrent(context)
            return 0
        }
        callbacks.getEGLDisplay = { cookie in Unmanaged<NativeNeptuneLibrary>.fromOpaque(cookie!).takeUnretainedValue().display }
        let initialize = symbol("virgl_renderer_init", as: (@convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer) -> Int32).self)
        // VIRGL_RENDERER_RENDER_SERVER. The device timer polls completions.
        // ASYNC_FENCE_CB alone disables that polling without creating a sync
        // thread, so Neptune's first context fence would never complete.
        let result = withUnsafeMutablePointer(to: &callbacks) { initialize(Unmanaged.passUnretained(self).toOpaque(), 1 << 9, $0) }
        log.info("virglrenderer (Neptune) init \(result)")
        started = result == 0
        return started
    }

    func shutdown() {
        guard started else { return }
        restoreCurrent()
        symbol("virgl_renderer_cleanup", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)(Unmanaged.passUnretained(self).toOpaque())
        started = false
        current = nil
        fence = nil
    }

    private func makeCurrent(_ context: UnsafeMutableRawPointer?) {
        _ = eglSymbol("eglMakeCurrent", as: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UInt32).self)(display, nil, nil, context)
    }
    func restoreCurrent() { if started { makeCurrent(current) } }
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
    func contextCreate(_ id: UInt32, flags: UInt32, name: [UInt8]) -> Int32 {
        name.withUnsafeBufferPointer {
            symbol("virgl_renderer_context_create_with_flags", as: (@convention(c) (UInt32, UInt32, UInt32, UnsafePointer<UInt8>?) -> Int32).self)(id, flags, UInt32(name.count), $0.baseAddress)
        }
    }
    func contextDestroy(_ id: UInt32) { symbol("virgl_renderer_context_destroy", as: (@convention(c) (UInt32) -> Void).self)(id) }
    func contextAttach(_ context: UInt32, _ id: UInt32) {
        symbol("virgl_renderer_ctx_attach_resource", as: (@convention(c) (Int32, Int32) -> Void).self)(Int32(bitPattern: context), Int32(bitPattern: id))
    }
    func contextDetach(_ context: UInt32, _ id: UInt32) {
        symbol("virgl_renderer_ctx_detach_resource", as: (@convention(c) (Int32, Int32) -> Void).self)(Int32(bitPattern: context), Int32(bitPattern: id))
    }
    func resourceCreate(_ args: inout VirglResourceArgs) -> Int32 {
        symbol("virgl_renderer_resource_create", as: (@convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?, UInt32) -> Int32).self)(&args, nil, 0)
    }
    func createBlob(id: UInt32, context: UInt32, memory: UInt32, flags: UInt32, blob: UInt64, size: UInt64,
                    iovecs: UnsafeMutablePointer<iovec>?, count: UInt32) -> Int32 {
        var args = BlobArgs(handle: id, context: context, memory: memory, flags: flags, blob: blob, size: size,
                            iovecs: iovecs.map { UnsafePointer($0) }, count: count)
        return symbol("virgl_renderer_resource_create_blob", as: (@convention(c) (UnsafeRawPointer) -> Int32).self)(&args)
    }
    func createBlobAt(id: UInt32, context: UInt32, flags: UInt32, size: UInt64, pointer: UnsafeMutableRawPointer) -> Int32 {
        var args = BlobArgs(handle: id, context: context, memory: 2, flags: flags, blob: 0, size: size, iovecs: nil, count: 0)
        return symbol("virgl_renderer_resource_create_blob_at", as: (@convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer) -> Int32).self)(&args, pointer)
    }
    func unref(_ id: UInt32) { symbol("virgl_renderer_resource_unref", as: (@convention(c) (UInt32) -> Void).self)(id) }
    func attach(_ id: UInt32, _ iovecs: UnsafeMutablePointer<iovec>, _ count: Int32) -> Int32 {
        symbol("virgl_renderer_resource_attach_iov", as: (@convention(c) (Int32, UnsafeMutablePointer<iovec>, Int32) -> Int32).self)(Int32(bitPattern: id), iovecs, count)
    }
    func detach(_ id: UInt32) {
        symbol("virgl_renderer_resource_detach_iov", as: (@convention(c) (Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self)(Int32(bitPattern: id), nil, nil)
    }
    func map(_ id: UInt32) -> (UnsafeMutableRawPointer, UInt64)? {
        var pointer: UnsafeMutableRawPointer?
        var size: UInt64 = 0
        let result = symbol("virgl_renderer_resource_map", as: (@convention(c) (UInt32, UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutablePointer<UInt64>) -> Int32).self)(id, &pointer, &size)
        guard result == 0, let pointer else { log.error("map of \(id) failed: \(result)"); return nil }
        return (pointer, size)
    }
    func unmap(_ id: UInt32) -> Int32 { symbol("virgl_renderer_resource_unmap", as: (@convention(c) (UInt32) -> Int32).self)(id) }
    func mapInfo(_ id: UInt32) -> UInt32 {
        var info: UInt32 = 0
        _ = symbol("virgl_renderer_resource_get_map_info", as: (@convention(c) (UInt32, UnsafeMutablePointer<UInt32>) -> Int32).self)(id, &info)
        return info
    }
    func transferWrite(_ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: inout VirglBox, offset: UInt64) -> Int32 {
        symbol("virgl_renderer_transfer_write_iov", as: (@convention(c) (UInt32, UInt32, Int32, UInt32, UInt32, UnsafeMutableRawPointer, UInt64, UnsafeMutableRawPointer?, UInt32) -> Int32).self)(
            id, context, Int32(bitPattern: level), stride, layerStride, &box, offset, nil, 0)
    }
    func transferRead(_ id: UInt32, context: UInt32, level: UInt32, stride: UInt32, layerStride: UInt32, box: inout VirglBox, offset: UInt64) -> Int32 {
        symbol("virgl_renderer_transfer_read_iov", as: (@convention(c) (UInt32, UInt32, UInt32, UInt32, UInt32, UnsafeMutableRawPointer, UInt64, UnsafeMutableRawPointer?, Int32) -> Int32).self)(
            id, context, level, stride, layerStride, &box, offset, nil, 0)
    }
    func submit(_ buffer: UnsafeMutableRawPointer, context: UInt32, words: Int32) -> Int32 {
        symbol("virgl_renderer_submit_cmd", as: (@convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32).self)(buffer, Int32(bitPattern: context), words)
    }
    func fence(_ fence: UInt32, context: UInt32) {
        _ = symbol("virgl_renderer_create_fence", as: (@convention(c) (Int32, UInt32) -> Int32).self)(Int32(bitPattern: fence), context)
    }
    func contextFence(_ context: UInt32, ring: UInt32, fence: UInt64) {
        _ = symbol("virgl_renderer_context_create_fence", as: (@convention(c) (UInt32, UInt32, UInt32, UInt64) -> Int32).self)(context, 0, ring, fence)
    }
}
