import AVFoundation
import Foundation
import HubWire

extension LinkCallAudio {
    static let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!

    static let opus: AVAudioFormat = {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frameSamples), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)!
    }()
}

/// Turns audio, in pieces of any length, into the call's packets. Use it from one thread at a time.
public final class LinkCallEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private var pending: [Int16] = []

    public init() throws {
        guard let converter = AVAudioConverter(from: LinkCallAudio.pcm, to: LinkCallAudio.opus) else {
            throw LinkError("This device cannot encode call audio.")
        }
        converter.bitRate = 32_000
        self.converter = converter
    }

    public func encode(_ samples: [Int16]) throws -> [Data] {
        pending += samples
        var packets: [Data] = []
        let size = LinkCallAudio.frameSamples
        while pending.count >= size {
            let input = AVAudioPCMBuffer(pcmFormat: LinkCallAudio.pcm, frameCapacity: AVAudioFrameCount(size))!
            input.frameLength = AVAudioFrameCount(size)
            pending.withUnsafeBufferPointer { input.int16ChannelData![0].update(from: $0.baseAddress!, count: size) }
            pending.removeFirst(size)
            let packet = AVAudioCompressedBuffer(format: LinkCallAudio.opus, packetCapacity: 1,
                                                 maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
            var given = false
            var error: NSError?
            let status = converter.convert(to: packet, error: &error) { _, state in
                if given { state.pointee = .noDataNow; return nil }
                given = true
                state.pointee = .haveData
                return input
            }
            if status == .error { throw error ?? LinkError("Call audio could not be encoded.") }
            if packet.byteLength > 0 { packets.append(Data(bytes: packet.data, count: Int(packet.byteLength))) }
        }
        return packets
    }
}

/// Turns the call's packets back into audio. Use it from one thread at a time.
public final class LinkCallDecoder: @unchecked Sendable {
    private let converter: AVAudioConverter

    public init() throws {
        guard let converter = AVAudioConverter(from: LinkCallAudio.opus, to: LinkCallAudio.pcm) else {
            throw LinkError("This device cannot decode call audio.")
        }
        self.converter = converter
    }

    public func decode(_ packet: Data) throws -> [Int16] {
        guard !packet.isEmpty else { return [] }
        let compressed = AVAudioCompressedBuffer(format: LinkCallAudio.opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        let output = AVAudioPCMBuffer(pcmFormat: LinkCallAudio.pcm, frameCapacity: AVAudioFrameCount(LinkCallAudio.frameSamples))!
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return compressed
        }
        if status == .error { throw error ?? LinkError("Call audio could not be decoded.") }
        return Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength)))
    }
}

/// The bot's voice waiting to be played. Packets arrive unevenly, so playing starts only once a
/// cushion has built up, and again after running dry; far behind, the oldest audio goes.
public final class LinkCallPlayout: @unchecked Sendable {
    private let cushion: Int
    private let limit: Int
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var playing = false

    /// By default 60 ms of cushion and at most half a second behind.
    public init(cushion: Int = LinkCallAudio.sampleRate * 6 / 100, limit: Int = LinkCallAudio.sampleRate / 2) {
        self.cushion = cushion
        self.limit = limit
    }

    public func append(_ more: [Int16]) {
        lock.withLock {
            samples += more
            if samples.count > limit { samples.removeFirst(samples.count - limit) }
        }
    }

    /// Fills `out`, with silence for whatever is not there yet.
    public func read(into out: inout [Int16]) {
        out.withUnsafeMutableBufferPointer { read(into: $0) }
    }

    public func read(into out: UnsafeMutableBufferPointer<Int16>) {
        lock.withLock {
            if !playing, samples.count >= cushion { playing = true }
            let count = playing ? min(samples.count, out.count) : 0
            for index in 0..<count { out[index] = samples[index] }
            for index in count..<out.count { out[index] = 0 }
            samples.removeFirst(count)
            if playing, samples.isEmpty, count < out.count { playing = false }
        }
    }
}
