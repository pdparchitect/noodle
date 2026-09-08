import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import NoodleCore

@main enum AnimatedBackgroundChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await runChecks(); print("Native background looping, mute, HEIC cycling, Reduce Motion, hidden-window pause and teardown passed"); exit(0) }
            catch { print("Background playback checks failed: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func runChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-playback-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("loop.mov")
        try await makeMovie(movie)
        let heic = directory.appendingPathComponent("dynamic.heic")
        let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 2, nil)!
        for color in [CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)] {
            let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        }
        precondition(CGImageDestinationFinalize(destination))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Background Playback Tests"
        let video = AnimatedWallpaperView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let dynamic = AnimatedWallpaperView(frame: NSRect(x: 320, y: 0, width: 320, height: 240))
        window.contentView!.addSubview(video); window.contentView!.addSubview(dynamic)
        video.configure(url: movie, kind: .video, reduceMotion: false)
        dynamic.configure(url: heic, kind: .dynamicImage, reduceMotion: false)
        window.orderFrontRegardless()
        defer { video.stop(); dynamic.stop(); window.orderOut(nil) }
        let playbackDeadline = Date().addingTimeInterval(24)
        while (video.completedLoops < 2 || dynamic.frameIndex != 1), Date() < playbackDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Playback observed: \(video.completedLoops) video loops; HEIC frame \(dynamic.frameIndex)/\(BackgroundMedia.frameCount(at: heic)); visible=\(window.occlusionState.contains(.visible))")
        precondition(video.player?.isMuted == true && video.player?.volume == 0)
        precondition(video.completedLoops >= 2, "Video did not loop")
        precondition(dynamic.frameIndex == 1, "HEIC did not advance")
        let frameLoopDeadline = Date().addingTimeInterval(12)
        while dynamic.frameIndex != 0, Date() < frameLoopDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(dynamic.frameIndex == 0, "HEIC did not loop back to its first frame")
        video.configure(url: movie, kind: .video, reduceMotion: true)
        dynamic.configure(url: heic, kind: .dynamicImage, reduceMotion: true)
        precondition(video.player?.rate == 0, "Reduce Motion must pause video")
        window.orderOut(nil)
        video.configure(url: movie, kind: .video, reduceMotion: false)
        try await Task.sleep(for: .milliseconds(300))
        precondition(video.player?.rate == 0, "Hidden window must pause video")
        let player = video.player!
        video.stop(); dynamic.stop()
        precondition(player.rate == 0 && player.items().isEmpty)

        if let path = CommandLine.arguments.dropFirst().first {
            let file = try await PreparedBackgroundFile.prepare(URL(fileURLWithPath: path))
            print("Apple HEIC: \(file.kind), \(BackgroundMedia.frameCount(at: file.url)) frames")
            precondition(file.kind == .dynamicImage)
            precondition(BackgroundMedia.image(at: file.url, index: BackgroundMedia.frameCount(at: file.url) - 1) != nil)
        }
    }

    static func makeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            precondition(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(index * 15), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 12)))
        }
        input.markAsFinished(); await writer.finishWriting()
        precondition(writer.status == .completed)
    }
}
