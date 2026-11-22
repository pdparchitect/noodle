import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

extension UTType {
    /// Metal shading language source, as Xcode names it. Noodle declares it too, for Macs without Xcode and for iPhone.
    public static let metalShader = UTType(importedAs: "com.apple.metal", conformingTo: .sourceCode)
}
#endif

/// Why a Metal file cannot be drawn as a background.
public enum ShaderError: LocalizedError, Equatable {
    case unreadable
    case noEntryPoint
    case notAColorShader(String)
    case unsupportedParameter(function: String, parameter: String)
    case missingStruct(String)
    case noDevice
    case compile(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "This Metal shader isn’t a readable text file of 1 MB or less."
        case .noEntryPoint: return "This file has no Metal shader to draw: Noodle needs a [[stitchable]] function that returns a colour, or a fragment function."
        case .notAColorShader(let name): return "\(name) moves pixels rather than colouring them, so it can’t be drawn as a background."
        case .unsupportedParameter(let function, let parameter): return "Noodle can’t fill \(parameter) of \(function)."
        case .missingStruct(let name): return "The structure \(name) isn’t defined in this file."
        case .noDevice: return "This device can’t draw Metal shaders."
        case .compile(let message): return "This Metal shader doesn’t compile.\n\n\(message)"
        }
    }
}

/// What a shader is given for one frame: seconds since it started, the drawable's size in pixels and
/// the pixels per point.
public struct ShaderFrame: Equatable, Sendable {
    public var time: Float
    public var width: Float
    public var height: Float
    public var scale: Float
    public var index: UInt32
    public init(time: Float, width: Float, height: Float, scale: Float = 1, index: UInt32 = 0) {
        self.time = time; self.width = width; self.height = height; self.scale = scale; self.index = index
    }
}

/// A buffer the fragment stage reads, laid out as Metal lays out its type, with each value it can tell
/// from its name filled in every frame and everything else left zero.
public struct ShaderBuffer: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case time, resolution, frame, aspect, pointer, scale, zero }
    public enum Scalar: Equatable, Sendable { case float, half, int, uint, short, ushort, bool }
    public struct Field: Equatable, Sendable {
        public var offset: Int
        public var scalar: Scalar
        public var count: Int
        public var role: Role
    }
    public var index: Int
    public var length: Int
    public var fields: [Field]

    public func bytes(for frame: ShaderFrame) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        for field in fields {
            let values = Self.values(field.role, frame: frame)
            for component in 0..<field.count {
                let value = component < values.count ? values[component] : 0
                let offset = field.offset + component * Self.stride(of: field.scalar)
                guard offset + Self.stride(of: field.scalar) <= length else { continue }
                Self.write(value, as: field.scalar, into: &bytes, at: offset)
            }
        }
        return bytes
    }

    static func values(_ role: Role, frame: ShaderFrame) -> [Float] {
        switch role {
        case .time: return [frame.time]
        // iResolution's third component is the pixel aspect ratio.
        case .resolution: return [frame.width, frame.height, 1, 1]
        case .frame: return [Float(frame.index)]
        case .aspect: return [frame.height > 0 ? frame.width / frame.height : 1]
        // Nothing points on a background: the middle stands in for a mouse or touch.
        case .pointer: return [frame.width / 2, frame.height / 2, 0, 0]
        case .scale: return [frame.scale]
        case .zero: return []
        }
    }

    static func stride(of scalar: Scalar) -> Int {
        switch scalar {
        case .float, .int, .uint: return 4
        case .half, .short, .ushort: return 2
        case .bool: return 1
        }
    }

    private static func write(_ value: Float, as scalar: Scalar, into bytes: inout [UInt8], at offset: Int) {
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { for (i, byte) in $0.enumerated() { bytes[offset + i] = byte } } }
        switch scalar {
        case .float: put(value.bitPattern.littleEndian)
        case .half: put(halfBits(value).littleEndian)
        case .int: put(Int32(clamping: Int(value.rounded(.down))).littleEndian)
        case .uint: put(UInt32(clamping: max(0, Int(value.rounded(.down)))).littleEndian)
        case .short: put(Int16(clamping: Int(value.rounded(.down))).littleEndian)
        case .ushort: put(UInt16(clamping: max(0, Int(value.rounded(.down)))).littleEndian)
        case .bool: bytes[offset] = value != 0 ? 1 : 0
        }
    }

    /// IEEE half precision, without Float16, which Intel Macs lack.
    static func halfBits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xff) - 127 + 15
        let mantissa = bits & 0x7fffff
        if value.isNaN { return 0x7e00 }
        if exponent >= 31 { return sign | 0x7c00 }
        if exponent <= 0 {
            guard exponent > -11 else { return sign }
            let full = mantissa | 0x800000
            return sign | UInt16(full >> UInt32(14 - exponent))
        }
        return sign | UInt16(exponent << 10) | UInt16(mantissa >> 13)
    }
}

/// A Metal file as agents write them when asked for a shader, turned into a program Noodle draws over a
/// whole view: a SwiftUI `[[stitchable]]` colour function, called from a fragment function Noodle adds,
/// or a fragment function of the file's own, given a full-screen vertex stage and its uniforms. The
/// entry point and what each argument means are told from the source alone, by type and name.
public struct ShaderProgram: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case stitchable, fragment }

    public static let wrapperVertex = "noodle_shader_vertex"
    public static let wrapperFragment = "noodle_shader_fragment"
    public static let wrapperVertexType = "NoodleShaderVertex"

    /// The function the file offers.
    public let entry: String
    public let style: Style
    /// The whole Metal source to compile: the file, adapted, and Noodle's functions after it.
    public let source: String
    public let fragmentFunction: String
    public let buffers: [ShaderBuffer]
    /// Texture and sampler slots the fragment stage declares, given a blank texture and a plain sampler.
    public let textures: [Int]
    public let samplers: [Int]

    /// Where the file starts in `source`, so compiler messages carry the file's own line numbers.
    static let prelude = """
        #include <metal_stdlib>
        namespace SwiftUI { struct Layer { half4 sample(float2 position) const { return half4(1.0h); } }; }

        """

    public init(source text: String) throws {
        let code = Self.strippingComments(text)
        let adapted = Self.adapting(text)
        let colorFunctions = Self.functions(in: code, after: #"\[\[\s*stitchable\s*\]\]\s*"#)
        if let function = colorFunctions.first(where: { Self.colorTypes.contains($0.returnType) }) {
            entry = function.name
            style = .stitchable
            fragmentFunction = Self.wrapperFragment
            let arguments = try Self.stitchableArguments(function)
            source = Self.prelude + "#line 1\n" + adapted + """


                #line 100000 "noodle"
                struct \(Self.wrapperVertexType) { float4 position [[position]]; };
                struct NoodleShaderUniforms { float2 size; float time; float scale; };
                \(Self.fullScreenVertex(Self.wrapperVertexType, positionField: "position", uvFields: []))
                fragment half4 \(Self.wrapperFragment)(\(Self.wrapperVertexType) in [[stage_in]], constant NoodleShaderUniforms &u [[buffer(0)]]) {
                    float2 position = in.position.xy / u.scale;
                    float2 size = u.size / u.scale;
                    return half4(\(function.name)(\(arguments.joined(separator: ", "))));
                }

                """
            buffers = [ShaderBuffer(index: 0, length: 16, fields: [
                .init(offset: 0, scalar: .float, count: 2, role: .resolution),
                .init(offset: 8, scalar: .float, count: 1, role: .time),
                .init(offset: 12, scalar: .float, count: 1, role: .scale),
            ])]
            textures = []
            samplers = []
            return
        }
        guard let function = Self.functions(in: code, after: #"\bfragment\s+"#).first else {
            if let distortion = colorFunctions.first { throw ShaderError.notAColorShader(distortion.name) }
            throw ShaderError.noEntryPoint
        }
        entry = function.name
        style = .fragment
        fragmentFunction = function.name
        let structs = Self.structs(in: code)
        var vertex = Self.fullScreenVertex(Self.wrapperVertexType, positionField: "position", uvFields: [])
        var vertexType = "struct \(Self.wrapperVertexType) { float4 position [[position]]; };\n"
        var buffers: [ShaderBuffer] = [], textures: [Int] = [], samplers: [Int] = []
        for parameter in function.parameters {
            let attribute = parameter.attribute?.replacingOccurrences(of: " ", with: "") ?? ""
            if attribute == "stage_in" {
                guard let fields = structs[parameter.type] else { throw ShaderError.missingStruct(parameter.type) }
                guard let position = fields.first(where: { $0.attribute?.replacingOccurrences(of: " ", with: "") == "position" }) else {
                    throw ShaderError.unsupportedParameter(function: function.name, parameter: parameter.name)
                }
                let uvs = fields.filter { $0.attribute == nil && ["float2", "half2"].contains($0.type) }
                vertex = Self.fullScreenVertex(parameter.type, positionField: position.name, uvFields: uvs.map { ($0.name, $0.type) })
                vertexType = ""
            } else if let index = Self.slot(attribute, "buffer") {
                buffers.append(Self.buffer(index: index, parameter: parameter, structs: structs))
            } else if let index = Self.slot(attribute, "texture") {
                guard parameter.type.hasPrefix("texture2d<") else {
                    throw ShaderError.unsupportedParameter(function: function.name, parameter: parameter.name)
                }
                textures.append(index)
            } else if let index = Self.slot(attribute, "sampler") {
                samplers.append(index)
            }
        }
        source = Self.prelude + "#line 1\n" + adapted + "\n\n#line 100000 \"noodle\"\n" + vertexType + vertex + "\n"
        self.buffers = buffers.sorted { $0.index < $1.index }
        self.textures = textures.sorted()
        self.samplers = samplers.sorted()
    }

    // MARK: - Generated code

    /// One triangle that covers the view. `uv` runs from 0 at the top left to 1 at the bottom right.
    private static func fullScreenVertex(_ type: String, positionField: String, uvFields: [(name: String, type: String)]) -> String {
        let uvs = uvFields.map { "    out.\($0.name) = \($0.type)(float2(p.x, 1.0 - p.y));\n" }.joined()
        return """
            vertex \(type) \(wrapperVertex)(uint id [[vertex_id]]) {
                float2 p = float2(float((id << 1) & 2), float(id & 2));
                \(type) out = {};
                out.\(positionField) = float4(p * 2.0 - 1.0, 0.0, 1.0);
            \(uvs)    return out;
            }
            """
    }

    private static let colorTypes: Set<String> = ["half4", "float4"]
    private static let scalarTypes: Set<String> = ["float", "half", "int", "uint", "short", "ushort", "bool"]

    /// SwiftUI passes a colour effect the pixel's position in points, its colour, then whatever the view
    /// adds; these are the usual additions, told by name, and the view's colour is white.
    private static func stitchableArguments(_ function: Function) throws -> [String] {
        var usedPosition = false, usedSize = false
        return try function.parameters.map { parameter in
            let type = parameter.type
            let role = role(of: parameter.name)
            if type == "SwiftUI::Layer" { return "SwiftUI::Layer()" }
            if parameter.isPointer { return "nullptr" }
            if ["float2", "half2"].contains(type) {
                if role == .resolution && !usedSize { usedSize = true; return "\(type)(size)" }
                if !usedPosition { usedPosition = true; return "\(type)(position)" }
                if !usedSize { usedSize = true; return "\(type)(size)" }
                return "\(type)(0.0)"
            }
            if colorTypes.contains(type) { return "\(type)(1.0)" }
            if ["float", "half"].contains(type) {
                switch role {
                case .time: return "\(type)(u.time)"
                case .aspect: return "\(type)(size.x / size.y)"
                case .scale: return "\(type)(u.scale)"
                // A value the view would have passed, such as a strength or speed: one leaves it as written.
                default: return "\(type)(1.0)"
                }
            }
            if scalarTypes.contains(type) || ["float3", "half3", "int2", "uint2"].contains(type) { return "\(type)(0)" }
            throw ShaderError.unsupportedParameter(function: function.name, parameter: parameter.name)
        }
    }

    // MARK: - Uniforms

    static func role(of name: String) -> ShaderBuffer.Role {
        var name = name
        // iTime, uTime, u_time and time all name the time.
        if name.count > 1, let first = name.first, "iu".contains(first), name.dropFirst().first?.isUppercase == true { name.removeFirst() }
        if name.lowercased().hasPrefix("u_") { name.removeFirst(2) }
        let lower = name.lowercased()
        if lower == "t" || lower.contains("time") || ["seconds", "secs", "elapsed", "clock"].contains(lower) { return .time }
        if lower.contains("resolution") || lower.contains("size") || lower.contains("viewport") || lower.contains("dimension")
            || lower.contains("bounds") || lower.contains("screen") || ["res", "wh", "canvas"].contains(lower) { return .resolution }
        if lower.contains("frame") { return .frame }
        if lower.contains("aspect") { return .aspect }
        if lower.contains("mouse") || lower.contains("touch") || lower.contains("pointer") || lower.contains("cursor") { return .pointer }
        if lower.contains("scale") || lower.contains("pixelratio") { return .scale }
        return .zero
    }

    private struct Layout { let scalar: ShaderBuffer.Scalar; let count: Int; let size: Int; let alignment: Int }

    /// Metal's sizes and alignments for the types a uniform is made of; a matrix is left zero.
    private static func layout(of type: String) -> Layout? {
        let packed = type.hasPrefix("packed_")
        let base = packed ? String(type.dropFirst(7)) : type
        if let match = base.wholeMatch(of: #/(float|half|int|uint|short|ushort|bool)([2-4])?(x[2-4])?/#) {
            let scalar: ShaderBuffer.Scalar = switch match.1 {
            case "float": .float
            case "half": .half
            case "int": .int
            case "uint": .uint
            case "short": .short
            case "ushort": .ushort
            default: .bool
            }
            let width = ShaderBuffer.stride(of: scalar)
            let rows = match.2.map { Int($0)! } ?? 1
            if let columns = match.3.map({ Int($0.dropFirst())! }) {
                guard !packed else { return nil }
                let column = width * (rows == 3 ? 4 : rows)
                return Layout(scalar: scalar, count: 0, size: column * columns, alignment: column)
            }
            if packed { return Layout(scalar: scalar, count: rows, size: width * rows, alignment: width) }
            let size = width * (rows == 3 ? 4 : rows)
            return Layout(scalar: scalar, count: rows, size: size, alignment: size)
        }
        return nil
    }

    private static func buffer(index: Int, parameter: Parameter, structs: [String: [Field]]) -> ShaderBuffer {
        // A pointer to an array, or a type this can't lay out, is read as zeros.
        let unknown = ShaderBuffer(index: index, length: 4096, fields: [])
        if parameter.isPointer && structs[parameter.type] == nil { return unknown }
        if let layout = layout(of: parameter.type) {
            let role = role(of: parameter.name)
            return ShaderBuffer(index: index, length: max(layout.size, 4),
                                fields: layout.count == 0 ? [] : [.init(offset: 0, scalar: layout.scalar, count: layout.count, role: role)])
        }
        guard let members = structs[parameter.type] else { return unknown }
        var offset = 0, alignment = 1
        var fields: [ShaderBuffer.Field] = []
        for member in members {
            guard let layout = layout(of: member.type) else { return unknown }
            offset = (offset + layout.alignment - 1) / layout.alignment * layout.alignment
            alignment = max(alignment, layout.alignment)
            if layout.count > 0 && member.arrayCount == 1 {
                fields.append(.init(offset: offset, scalar: layout.scalar, count: layout.count, role: role(of: member.name)))
            }
            offset += layout.size * member.arrayCount
        }
        let length = (offset + alignment - 1) / alignment * alignment
        return ShaderBuffer(index: index, length: max(length, 4), fields: fields)
    }

    private static func slot(_ attribute: String, _ kind: String) -> Int? {
        guard let match = attribute.wholeMatch(of: #/(\w+)\((\d+)\)/#), match.1 == kind else { return nil }
        return Int(match.2)
    }

    // MARK: - Reading the source

    struct Parameter: Equatable {
        var type: String
        var name: String
        var attribute: String?
        var isPointer: Bool
    }

    struct Function: Equatable {
        var returnType: String
        var name: String
        var parameters: [Parameter]
    }

    struct Field: Equatable {
        var type: String
        var name: String
        var attribute: String?
        var arrayCount: Int
    }

    /// SwiftUI's header is not there at run time, and its attribute only matters to SwiftUI: what the file
    /// uses of it, `SwiftUI::Layer`, the prelude provides.
    private static func adapting(_ text: String) -> String {
        text.replacing(#/#\s*include\s*<SwiftUI\/[^>]*>/#, with: "")
            .replacing(#/\[\[\s*stitchable\s*\]\]/#, with: "")
    }

    static func strippingComments(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = Array(text.unicodeScalars)[...]
        var inString = false
        while let scalar = iterator.first {
            iterator = iterator.dropFirst()
            if inString {
                result.unicodeScalars.append(scalar)
                if scalar == "\\", let next = iterator.first { result.unicodeScalars.append(next); iterator = iterator.dropFirst() }
                else if scalar == "\"" { inString = false }
                continue
            }
            if scalar == "\"" { inString = true; result.unicodeScalars.append(scalar); continue }
            if scalar == "/", iterator.first == "/" {
                while let next = iterator.first, next != "\n" { iterator = iterator.dropFirst() }
                result.append(" ")
                continue
            }
            if scalar == "/", iterator.first == "*" {
                iterator = iterator.dropFirst()
                while let next = iterator.first {
                    iterator = iterator.dropFirst()
                    if next == "*", iterator.first == "/" { iterator = iterator.dropFirst(); break }
                    if next == "\n" { result.append("\n") }
                }
                result.append(" ")
                continue
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Functions whose declaration follows `marker`, as `marker [[attributes]] type name(parameters)`.
    static func functions(in code: String, after marker: String) -> [Function] {
        guard let regex = try? Regex(marker + #"(?:\[\[[^\]]*\]\]\s*)*([A-Za-z_][\w:]*(?:<[^>()]*>)?)\s+([A-Za-z_]\w*)\s*\("#) else { return [] }
        return code.matches(of: regex).compactMap { match in
            guard let returnType = match.output[1].substring, let name = match.output[2].substring,
                  let list = balanced(code, from: match.range.upperBound) else { return nil }
            return Function(returnType: String(returnType), name: String(name),
                            parameters: splitTopLevel(list).compactMap(parameter))
        }
    }

    /// The text up to the parenthesis that closes the one just opened before `start`.
    private static func balanced(_ code: String, from start: String.Index) -> String? {
        var depth = 1, index = start
        while index < code.endIndex {
            switch code[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(code[start..<index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }

    private static func splitTopLevel(_ list: String, separator: Character = ",") -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for character in list {
            switch character {
            case "(", "<", "[", "{": depth += 1
            case ")", ">", "]", "}": depth -= 1
            default: break
            }
            if character == separator && depth == 0 { parts.append(current); current = "" } else { current.append(character) }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static let qualifiers: Set<String> = ["const", "constant", "device", "thread", "threadgroup", "ray_data", "object_data", "volatile", "restrict"]

    /// `constant Uniforms &u [[buffer(0)]]`, `texture2d<float> tex [[texture(0)]]` or `float2 position`.
    private static func parameter(_ text: String) -> Parameter? {
        var text = text
        var attribute: String?
        if let match = text.firstMatch(of: #/\[\[\s*(.*?)\s*\]\]/#) {
            attribute = String(match.1)
            text.removeSubrange(match.range)
        }
        let isPointer = text.contains("*")
        text = text.replacingOccurrences(of: "&", with: " ").replacingOccurrences(of: "*", with: " ")
        // Spaces inside a template, as in `texture2d<float, access::sample>`, stay with its type.
        var tokens: [String] = [], current = "", depth = 0
        for character in text {
            if character == "<" { depth += 1 } else if character == ">" { depth -= 1 }
            if character.isWhitespace && depth == 0 {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if !(character.isWhitespace) { current.append(character) }
        }
        if !current.isEmpty { tokens.append(current) }
        tokens.removeAll { qualifiers.contains($0) }
        guard tokens.count >= 2, let name = tokens.last else { return nil }
        let type = tokens.dropLast().joined(separator: " ").replacingOccurrences(of: "metal::", with: "")
        return Parameter(type: type, name: name, attribute: attribute, isPointer: isPointer)
    }

    static func structs(in code: String) -> [String: [Field]] {
        var structs: [String: [Field]] = [:]
        for match in code.matches(of: #/\b(?:struct|typedef\s+struct)\s+([A-Za-z_]\w*)\s*\{([^{}]*)\}/#) {
            var fields: [Field] = []
            for declaration in splitTopLevel(String(match.2), separator: ";") {
                var text = declaration
                var attribute: String?
                if let found = text.firstMatch(of: #/\[\[\s*(.*?)\s*\]\]/#) {
                    attribute = String(found.1)
                    text.removeSubrange(found.range)
                }
                let parts = splitTopLevel(text)
                guard let first = parts.first else { continue }
                let tokens = first.split(whereSeparator: \.isWhitespace).map(String.init).filter { !qualifiers.contains($0) }
                guard tokens.count >= 2 else { continue }
                let type = tokens.dropLast().joined(separator: " ").replacingOccurrences(of: "metal::", with: "")
                for (offset, part) in parts.enumerated() {
                    var name = offset == 0 ? tokens.last! : part
                    var count = 1
                    if let array = name.firstMatch(of: #/\[\s*(\d+)\s*\]/#) {
                        count = Int(array.1) ?? 1
                        name.removeSubrange(array.range)
                    }
                    fields.append(Field(type: type, name: name.trimmingCharacters(in: .whitespaces), attribute: attribute, arrayCount: count))
                }
            }
            structs[String(match.1)] = fields
        }
        return structs
    }
}
