import Foundation
import Metal
import XCTest
@testable import NoodleWallpaperCore

/// Shaders written the ways agents write them when asked for "a Metal shader": SwiftUI's
/// `[[stitchable]]` functions and plain fragment functions with their own vertex stage.
final class ShaderProgramTests: XCTestCase {
    static let stitchable = """
        #include <metal_stdlib>
        #include <SwiftUI/SwiftUI_Metal.h>
        using namespace metal;

        // [[ stitchable ]] half4 commented(float2 position) is not the entry.
        [[ stitchable ]] half4 aurora(float2 position, half4 color, float2 size, float time) {
            float2 uv = position / size;
            float glow = 0.5 + 0.5 * sin(uv.x * 6.0 + time);
            return half4(half3(uv.y, glow, 1.0 - uv.y), 1.0h) * color.a;
        }
        """

    static let fragment = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct Uniforms {
            float time;
            float2 resolution;
        };

        vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
            float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
            VertexOut out;
            out.position = float4(positions[vertexID], 0, 1);
            out.uv = positions[vertexID] * 0.5 + 0.5;
            return out;
        }

        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                       constant Uniforms &uniforms [[buffer(0)]]) {
            float2 p = (in.uv - 0.5) * float2(uniforms.resolution.x / uniforms.resolution.y, 1.0) * 3.0;
            float v = sin(p.x + uniforms.time) + sin(p.y * 1.3 - uniforms.time);
            return float4(0.5 + 0.5 * cos(v + float3(0.0, 2.1, 4.2)), 1.0);
        }
        """

    func testStitchableFunctionIsCalledWithPositionColorSizeAndTime() throws {
        let program = try ShaderProgram(source: Self.stitchable)
        XCTAssertEqual(program.entry, "aurora")
        XCTAssertEqual(program.style, .stitchable)
        XCTAssertFalse(program.source.contains("SwiftUI_Metal.h"))
        XCTAssertFalse(program.source.contains("stitchable ]]"))
        XCTAssertTrue(program.source.contains("aurora(float2(position), half4(1.0), float2(size), float(u.time))"), program.source)
        XCTAssertEqual(program.fragmentFunction, ShaderProgram.wrapperFragment)
        XCTAssertEqual(program.buffers.map(\.index), [0])
        // Size in pixels, time, then the pixels per point that turn them into SwiftUI's points.
        XCTAssertEqual(floats(program.buffers[0].bytes(for: ShaderFrame(time: 2, width: 800, height: 600, scale: 2))),
                       [800, 600, 2, 2])
    }

    func testStitchableFunctionWithFewerArgumentsGetsOnlyThose() throws {
        let program = try ShaderProgram(source: """
            #include <metal_stdlib>
            using namespace metal;
            [[stitchable]] float4 stripes(float2 pos, float iTime) {
                return float4(fract(pos.x * 0.01 + iTime), 0.2, 0.4, 1.0);
            }
            """)
        XCTAssertEqual(program.entry, "stripes")
        XCTAssertTrue(program.source.contains("stripes(float2(position), float(u.time))"), program.source)
    }

    func testDistortionShaderIsNotABackground() {
        XCTAssertThrowsError(try ShaderProgram(source: """
            [[ stitchable ]] float2 wave(float2 position, float time) { return position + sin(time); }
            """)) { error in
            XCTAssertEqual(error as? ShaderError, .notAColorShader("wave"))
        }
    }

    func testFragmentFunctionGetsAFullScreenVertexStageAndItsUniformStruct() throws {
        let program = try ShaderProgram(source: Self.fragment)
        XCTAssertEqual(program.entry, "fragmentShader")
        XCTAssertEqual(program.style, .fragment)
        XCTAssertEqual(program.fragmentFunction, "fragmentShader")
        XCTAssertTrue(program.source.contains("vertex VertexOut \(ShaderProgram.wrapperVertex)("), program.source)
        XCTAssertTrue(program.source.contains("out.uv = float2("), program.source)
        XCTAssertEqual(program.buffers.count, 1)
        XCTAssertEqual(program.buffers[0].index, 0)
        XCTAssertEqual(program.buffers[0].length, 16)
        // float time at 0, float2 resolution aligned to 8.
        XCTAssertEqual(floats(program.buffers[0].bytes(for: ShaderFrame(time: 2, width: 800, height: 600, scale: 2))),
                       [2, 0, 800, 600])
    }

    func testFragmentFunctionWithSeparateTimeAndResolutionBuffers() throws {
        let program = try ShaderProgram(source: """
            #include <metal_stdlib>
            using namespace metal;
            fragment half4 waves(float4 pos [[position]], constant float &iTime [[ buffer(0) ]],
                                 constant float2& u_resolution [[buffer(1)]], texture2d<float> noise [[texture(2)]],
                                 sampler s [[sampler(0)]]) {
                float2 uv = pos.xy / u_resolution;
                return half4(uv.x, uv.y, 0.5 + 0.5 * sin(iTime), 1.0);
            }
            """)
        XCTAssertEqual(program.entry, "waves")
        XCTAssertTrue(program.source.contains("\(ShaderProgram.wrapperVertexType) \(ShaderProgram.wrapperVertex)("), program.source)
        let frame = ShaderFrame(time: 1.5, width: 640, height: 480, scale: 1)
        XCTAssertEqual(program.buffers.map(\.index), [0, 1])
        XCTAssertEqual(floats(program.buffers[0].bytes(for: frame)), [1.5])
        XCTAssertEqual(floats(program.buffers[1].bytes(for: frame)), [640, 480])
        XCTAssertEqual(program.textures, [2])
        XCTAssertEqual(program.samplers, [0])
    }

    func testFileWithoutAnEntryPointSaysSo() {
        for source in ["", "// fragment float4 hidden(float4 p [[position]]) { return p; }",
                       "kernel void compute(uint2 gid [[thread_position_in_grid]]) {}"] {
            XCTAssertThrowsError(try ShaderProgram(source: source)) { error in
                XCTAssertEqual(error as? ShaderError, .noEntryPoint)
                XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
            }
        }
    }

    func testBothStylesCompileAndDraw() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        for source in [Self.stitchable, Self.fragment] {
            let pipeline = try await ShaderPipeline.compile(ShaderProgram(source: source))
            let image = try pipeline.image(width: 64, height: 40, time: 1)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 40)
        }
    }

    func testCompilerErrorIsReportedWithTheFilesLineNumbers() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let program = try ShaderProgram(source: """
            #include <metal_stdlib>
            using namespace metal;
            fragment float4 broken(float4 p [[position]]) {
                return float4(p.x, undefinedThing, 0, 1);
            }
            """)
        do {
            _ = try await ShaderPipeline.compile(program)
            XCTFail("Compiled a broken shader")
        } catch let ShaderError.compile(message) {
            XCTAssertTrue(message.contains("undefinedThing"), message)
            XCTAssertTrue(message.contains("line 4:"), message)
        }
    }

    func testPreparedShaderFileIsCheckedAndKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-shader-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("Aurora.metal")
        try Self.stitchable.write(to: good, atomically: true, encoding: .utf8)
        let prepared = try await PreparedBackgroundFile.prepare(good)
        XCTAssertEqual(prepared.kind, .shader)
        XCTAssertEqual(prepared.url.pathExtension, "metal")
        XCTAssertEqual(try String(contentsOf: prepared.url, encoding: .utf8), Self.stitchable)
        XCTAssertTrue(BackgroundMedia.allowedContentTypes.contains(.metalShader))

        let empty = folder.appendingPathComponent("empty.metal")
        try "using namespace metal;".write(to: empty, atomically: true, encoding: .utf8)
        do {
            _ = try await PreparedBackgroundFile.prepare(empty)
            XCTFail("Accepted a file without a shader")
        } catch { XCTAssertEqual(error as? ShaderError, .noEntryPoint) }
    }

    private func floats(_ bytes: [UInt8]) -> [Float] {
        stride(from: 0, to: bytes.count, by: 4).map { offset in
            bytes[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        }
    }
}
