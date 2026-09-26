import CoreGraphics
import Foundation

/// One encoded H.264 frame of a surface: what a companion sends and a viewer shows. A key frame
/// carries the parameter sets a viewer needs to start, so anyone may join at the next one.
public struct SurfacePacket: Equatable, Sendable {
    /// Counts up from 1 within one surface session.
    public var sequence: UInt64
    public var keyFrame: Bool
    /// The surface's size in points, which input is given in.
    public var width: Double
    public var height: Double
    /// SPS and PPS, on key frames only.
    public var parameterSets: [Data]
    /// The frame's NAL units, each with a four-byte big-endian length (AVCC).
    public var sample: Data

    public init(sequence: UInt64, keyFrame: Bool, width: Double, height: Double, parameterSets: [Data], sample: Data) {
        self.sequence = sequence
        self.keyFrame = keyFrame
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.sample = sample
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// The first byte of encoded packets, which no JSON message starts with.
    public static let formatByte: UInt8 = 1

    /// Packets as bytes: a version, then each packet with its fields and lengths, so no JSON or base64
    /// sits between the encoder and the screen.
    public static func encode(_ packets: [SurfacePacket]) -> Data {
        var data = Data([formatByte])
        data.append(UInt32(packets.count))
        for packet in packets {
            data.append(packet.sequence)
            data.append(UInt8(packet.keyFrame ? 1 : 0))
            data.append(packet.width.bitPattern)
            data.append(packet.height.bitPattern)
            data.append(UInt8(packet.parameterSets.count))
            for set in packet.parameterSets { data.append(UInt32(set.count)); data.append(set) }
            data.append(UInt32(packet.sample.count))
            data.append(packet.sample)
        }
        return data
    }

    public static func decode(_ data: Data) -> [SurfacePacket]? {
        var reader = ByteReader(data)
        guard reader.byte() == formatByte, let count = reader.uint32(), count <= 1024 else { return nil }
        var packets: [SurfacePacket] = []
        for _ in 0..<count {
            guard let sequence = reader.uint64(), let key = reader.byte(), let width = reader.uint64(), let height = reader.uint64(),
                  let setCount = reader.byte(), setCount <= 8 else { return nil }
            var sets: [Data] = []
            for _ in 0..<setCount {
                guard let length = reader.uint32(), let set = reader.bytes(Int(length)) else { return nil }
                sets.append(set)
            }
            guard let length = reader.uint32(), let sample = reader.bytes(Int(length)) else { return nil }
            packets.append(SurfacePacket(sequence: sequence, keyFrame: key == 1, width: Double(bitPattern: width),
                                         height: Double(bitPattern: height), parameterSets: sets, sample: sample))
        }
        return reader.atEnd ? packets : nil
    }
}

private struct ByteReader {
    let data: Data
    var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }
    var atEnd: Bool { offset == data.endIndex }
    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, count <= data.endIndex - offset else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }
    mutating func byte() -> UInt8? { bytes(1)?.first }
    mutating func uint32() -> UInt32? { bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } } }
    mutating func uint64() -> UInt64? { bytes(8).map { $0.reduce(0) { $0 << 8 | UInt64($1) } } }
}

private extension Data {
    mutating func append(_ value: UInt32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func append(_ value: UInt64) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func append(_ value: UInt8) { append(contentsOf: [value]) }
}
