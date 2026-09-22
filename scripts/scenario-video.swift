// Reframes a scenario recording for a given aspect ratio: the window at its own size,
// centred with a margin on the film's background colour. Used by scripts/scenario.sh.
import AVFoundation
import CoreImage

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("scenario-video: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else { fail("usage: scenario-video.swift INPUT OUTPUT W:H black|white") }
let input = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
let parts = arguments[3].split(separator: ":").compactMap { Double($0) }
guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("\(arguments[3]) is not an aspect ratio like 16:9") }
let (ratioWidth, ratioHeight) = (parts[0], parts[1])
guard ["black", "white"].contains(arguments[4]) else { fail("the background is black or white") }
let light = arguments[4] == "white"

/// Even, because H.264 encodes in pairs of pixels.
func even(_ value: Double) -> Double { (value / 2).rounded() * 2 }

let asset = AVURLAsset(url: input)
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("\(input.lastPathComponent) has no video") }
        let natural = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let source = CGSize(width: abs(natural.width), height: abs(natural.height))

        // The recording already frames the window; this only grows it to the asked-for shape.
        let boxed = source
        var canvas = boxed.width / boxed.height > ratioWidth / ratioHeight
            ? CGSize(width: boxed.width, height: boxed.width * ratioHeight / ratioWidth)
            : CGSize(width: boxed.height * ratioWidth / ratioHeight, height: boxed.height)
        // Deliver at a sensible size rather than whatever the display happened to give.
        let shrink = min(1, 1920 / max(canvas.width, canvas.height))
        canvas = CGSize(width: even(canvas.width * shrink), height: even(canvas.height * shrink))
        let scale = shrink
        let origin = CGPoint(x: ((canvas.width - source.width * scale) / 2).rounded(),
                             y: ((canvas.height - source.height * scale) / 2).rounded())

        let grey: CGFloat = light ? 1 : 0
        let background = CIImage(color: CIColor(red: grey, green: grey, blue: grey, alpha: 1))
            .cropped(to: CGRect(origin: .zero, size: canvas))
        let placement = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))

        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let placed = request.sourceImage.transformed(by: placement)
            request.finish(with: placed.composited(over: background), context: nil)
        }
        composition.renderSize = canvas

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            fail("could not start an export")
        }
        export.videoComposition = composition
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .mp4)
        print("\(Int(canvas.width))x\(Int(canvas.height)) \(output.path)")
        semaphore.signal()
    } catch {
        fail(error.localizedDescription)
    }
}
semaphore.wait()
