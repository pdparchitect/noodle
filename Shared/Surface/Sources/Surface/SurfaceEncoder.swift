import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Encodes pictures of a surface as H.264 with the Mac's video encoder, tuned for a live view:
/// no frame reordering, a key frame every two seconds, and one frame out for each frame in.
public final class SurfaceEncoder {
    private var session: VTCompressionSession?
    private var pixels: (width: Int, height: Int) = (0, 0)
    private var frame: Int64 = 0
    private let maxPixelSize: Int
    private let fps: Int32

    public init(maxPixelSize: Int = 1600, fps: Int32 = 30) {
        self.maxPixelSize = maxPixelSize
        self.fps = fps
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    /// The encoded frame, with the parameter sets when it is a key frame. `size` is the surface's
    /// size in points. `keyFrame` asks for one now, as when a new viewer arrives. `fitting` is the
    /// most pixels a viewer shows, rounded up in steps of 128 so resizing a window does not
    /// restart the encoder at every pixel; a new size starts at a key frame.
    public func encode(_ image: CGImage, size: CGSize, keyFrame: Bool = false,
                       fitting: CGSize? = nil) throws -> (sample: Data, parameterSets: [Data], keyFrame: Bool)? {
        var scale = min(1, Double(maxPixelSize) / Double(max(image.width, image.height)))
        if let fitting, fitting.width > 0, fitting.height > 0 {
            let box = (width: (fitting.width / 128).rounded(.up) * 128, height: (fitting.height / 128).rounded(.up) * 128)
            scale = min(scale, box.width / Double(image.width), box.height / Double(image.height))
        }
        // H.264 wants even dimensions.
        let width = max(2, Int(Double(image.width) * scale) & ~1), height = max(2, Int(Double(image.height) * scale) & ~1)
        if session == nil || pixels != (width, height) { try start(width: width, height: height) }
        guard let session, let buffer = Self.pixelBuffer(image, width: width, height: height) else { return nil }
        var result: (Data, [Data], Bool)?
        let properties = (keyFrame || frame == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : [:]) as CFDictionary
        let time = CMTime(value: frame, timescale: fps)
        frame += 1
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time,
                                                     duration: CMTime(value: 1, timescale: fps), frameProperties: properties,
                                                     infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample else { return }
            result = Self.unpack(sample)
        }
        guard status == noErr else { throw SurfaceEncoderError(status: status) }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: time)
        return result.map { (sample: $0.0, parameterSets: $0.1, keyFrame: $0.2) }
    }

    private func start(width: Int, height: Int) throws {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
                                                refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw SurfaceEncoderError(status: status) }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // Sharp text matters more than smooth motion for a desktop or page.
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: (width * height * 3) as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        pixels = (width, height)
        frame = 0
    }

    private static func pixelBuffer(_ image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func unpack(_ sample: CMSampleBuffer) -> (Data, [Data], Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0, pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let data = Data(bytes: pointer, count: length)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var sets: [Data] = []
        if keyFrame, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var set: UnsafePointer<UInt8>?, size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &set,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let set {
                    sets.append(Data(bytes: set, count: size))
                }
            }
        }
        return (data, sets, keyFrame)
    }
}

public struct SurfaceEncoderError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { "The video encoder failed (\(status))." }
}

/// Turns packets back into sample buffers a display layer or decompression session can take.
public enum SurfaceSamples {
    public static func format(_ packet: SurfacePacket) -> CMVideoFormatDescription? {
        guard packet.parameterSets.count >= 2 else { return nil }
        var format: CMVideoFormatDescription?
        let sets = packet.parameterSets.map { [UInt8]($0) }
        let status = sets[0].withUnsafeBufferPointer { sps in
            sets[1].withUnsafeBufferPointer { pps in
                let pointers = [sps.baseAddress!, pps.baseAddress!]
                let sizes = [sets[0].count, sets[1].count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                           parameterSetSizes: sizes, nalUnitHeaderLength: 4,
                                                                           formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    public static func sample(_ packet: SurfacePacket, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = packet.sample.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block,
              packet.sample.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                            dataLength: length) }) == noErr else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}
