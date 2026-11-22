#if canImport(Metal) && canImport(CoreGraphics)
import CoreGraphics
import Foundation
import Metal

/// A shader program compiled for this device's GPU, ready to draw frames into a view or a picture.
/// Compiling takes a moment, so it happens off the main thread and each source is compiled once.
public final class ShaderPipeline: @unchecked Sendable {
    public let program: ShaderProgram
    public let device: MTLDevice
    let state: MTLRenderPipelineState
    private let blank: MTLTexture?
    private let sampler: MTLSamplerState?
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init(program: ShaderProgram, device: MTLDevice, state: MTLRenderPipelineState) {
        self.program = program
        self.device = device
        self.state = state
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        blank = program.textures.isEmpty ? nil : device.makeTexture(descriptor: descriptor)
        blank?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        sampler = program.samplers.isEmpty ? nil : device.makeSamplerState(descriptor: samplerDescriptor)
    }

    private static let cache = Cache()

    /// The file at `url`, read, understood and compiled; the same text again comes from memory.
    public static func load(_ url: URL) async throws -> ShaderPipeline {
        let source = try ShaderSourceFile.read(url)
        return try await compile(ShaderProgram(source: source))
    }

    public static func compile(_ program: ShaderProgram, device: MTLDevice? = MTLCreateSystemDefaultDevice()) async throws -> ShaderPipeline {
        guard let device else { throw ShaderError.noDevice }
        if let kept = cache.pipeline(for: program.source, device: device) { return kept }
        let library: MTLLibrary
        do {
            library = try await device.makeLibrary(source: program.source, options: MTLCompileOptions())
        } catch {
            throw ShaderError.compile(Self.compilerMessage(error))
        }
        guard let vertex = library.makeFunction(name: ShaderProgram.wrapperVertex),
              let fragment = library.makeFunction(name: program.fragmentFunction) else { throw ShaderError.noEntryPoint }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        let state: MTLRenderPipelineState
        do { state = try await device.makeRenderPipelineState(descriptor: descriptor) }
        catch { throw ShaderError.compile(Self.compilerMessage(error)) }
        let pipeline = ShaderPipeline(program: program, device: device, state: state)
        cache.keep(pipeline, for: program.source)
        return pipeline
    }

    /// The compiler's own words, naming the file rather than Metal's buffer and leaving out Noodle's part.
    static func compilerMessage(_ error: Error) -> String {
        let text = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? error.localizedDescription
        return text.replacingOccurrences(of: "Compilation failed: \n\n", with: "")
            .replacingOccurrences(of: "Compilation failed:", with: "")
            .replacingOccurrences(of: "program_source:", with: "line ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Draws one frame with `encoder`, which targets a single colour attachment in `pixelFormat`.
    public func encode(_ encoder: MTLRenderCommandEncoder, frame: ShaderFrame) {
        encoder.setRenderPipelineState(state)
        for buffer in program.buffers {
            let bytes = buffer.bytes(for: frame)
            bytes.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: bytes.count, index: buffer.index) }
        }
        for index in program.textures { encoder.setFragmentTexture(blank, index: index) }
        for index in program.samplers { encoder.setFragmentSamplerState(sampler, index: index) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// One frame as a picture, `width` by `height` pixels, `time` seconds in.
    public func image(width: Int, height: Int, time: Float, scale: Float = 1) throws -> CGImage {
        guard width > 0, height > 0, let queue = device.makeCommandQueue() else { throw ShaderError.noDevice }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let bytesPerRow = width * 4
        guard let target = device.makeTexture(descriptor: descriptor),
              let output = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else { throw ShaderError.noDevice }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { throw ShaderError.noDevice }
        encode(encoder, frame: ShaderFrame(time: time, width: Float(width), height: Float(height), scale: scale))
        encoder.endEncoding()
        guard let blit = commands.makeBlitCommandEncoder() else { throw ShaderError.noDevice }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: output, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw ShaderError.compile(error.localizedDescription) }
        // Shaders may leave alpha below one; a background is opaque.
        let pixels = output.contents().assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 3, to: bytesPerRow * height, by: 4) { pixels[offset] = 255 }
        let data = Data(bytes: output.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw ShaderError.noDevice
        }
        return image
    }

    /// A still of the shader at `url`: what Reduce Motion and Low Power Mode show, and the picture shown
    /// while the live one starts. Two seconds in, so it is past any fade in from black.
    public static func still(of url: URL, width: Int, height: Int, scale: Float = 1) async throws -> CGImage {
        try await load(url).image(width: width, height: height, time: stillTime, scale: scale)
    }

    public static let stillTime: Float = 2

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var pipelines: [String: ShaderPipeline] = [:]
        private var order: [String] = []

        func pipeline(for source: String, device: MTLDevice) -> ShaderPipeline? {
            lock.lock(); defer { lock.unlock() }
            guard let pipeline = pipelines[source], pipeline.device === device else { return nil }
            return pipeline
        }

        func keep(_ pipeline: ShaderPipeline, for source: String) {
            lock.lock(); defer { lock.unlock() }
            if pipelines[source] == nil { order.append(source) }
            pipelines[source] = pipeline
            // A few conversations' worth; each is small.
            while order.count > 8 { pipelines[order.removeFirst()] = nil }
        }
    }
}

/// Reads a shader file as text, refusing anything too large to be source.
public enum ShaderSourceFile {
    public static let maximumBytes = 1_048_576

    public static func isShader(_ url: URL) -> Bool { url.pathExtension.lowercased() == "metal" }

    public static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= maximumBytes,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ShaderError.unreadable
        }
        return text
    }
}
#endif
