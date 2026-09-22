// Finishes a scenario recording. `sound` lays the keystrokes the app reported onto a
// track of its own; `frame` grows the picture to an aspect ratio, the window at its own
// size on the film's background colour. Used by scripts/scenario.sh.
import AVFoundation
import CoreImage

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("scenario-video: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: scenario-video.swift frame|sound ...") }
let mode = arguments[1]

/// Typing sits under the picture, not over it: loud enough to hear, quiet enough that
/// nobody reaches for the volume.
let level: Float = 0.14

/// Brings the loudest moment to `level`, so a track is never a surprise.
func quieten(_ samples: inout [Float]) {
    let peak = samples.map(abs).max() ?? 0
    guard peak > 0 else { return }
    let scale = level / peak
    for index in samples.indices { samples[index] *= scale }
}

/// Even, because H.264 encodes in pairs of pixels.
func even(_ value: Double) -> Double { (value / 2).rounded() * 2 }

/// A ringing filter, for the short tone a struck thing gives off.
struct Resonator {
    private let feedback: Float, damping: Float, drive: Float
    private var previous: Float = 0, older: Float = 0

    init(frequency: Double, decay: Double, rate: Double) {
        let radius = Float(exp(-1 / (decay * rate)))
        feedback = 2 * radius * Float(cos(2 * .pi * frequency / rate))
        damping = -radius * radius
        // A narrow resonance is loud out of all proportion to what goes in, so it is
        // scaled back to roughly unity; otherwise it drowns out the transient.
        drive = 1 - radius
    }

    mutating func next(_ input: Float) -> Float {
        let value = input * drive + feedback * previous + damping * older
        older = previous
        previous = value
        return value
    }
}

/// One keystroke, shaped after a recording of a mechanical keyboard: a tap around
/// 3 kHz doing most of the work, a little mid body, and the low thud of the case under
/// it, each a pinprick of noise ringing a resonance. The tap is short and the thud
/// quiet, because the other way round is a thump rather than a click.
func strike(into samples: inout [Float], at start: Int, rate: Double) {
    let gain = Float.random(in: 0.55...0.8)
    var tap = Resonator(frequency: Double.random(in: 3400...4200), decay: 0.0018, rate: rate)
    var body = Resonator(frequency: Double.random(in: 1300...1700), decay: 0.0025, rate: rate)
    var thud = Resonator(frequency: Double.random(in: 130...175), decay: 0.012, rate: rate)
    // A key is struck twice: the tap, then the quieter knock as it bottoms out.
    let bottomsOut = Int(Double.random(in: 0.006...0.011) * rate)
    var drift: Float = 0, bright: Float = 0, brighter: Float = 0
    for index in 0..<Int(0.06 * rate) {
        let at = start + index
        guard at >= 0, at < samples.count else { continue }
        let time = Double(index) / rate
        var excitement = Float.random(in: -1...1) * Float(exp(-time / 0.00035))
        if index >= bottomsOut {
            let since = Double(index - bottomsOut) / rate
            excitement += Float.random(in: -1...1) * Float(exp(-since / 0.0008)) * 0.6
        }
        // Rolled off at the top over two stages, or the bare transient hisses.
        bright += 0.45 * (excitement - bright)
        brighter += 0.45 * (bright - brighter)
        var value = tap.next(excitement) + body.next(excitement) * 0.05
            + thud.next(excitement) * 0.018 + brighter * 1.0
        // Only the rumble below hearing is taken out; the thud of the case stays.
        drift += 0.006 * (value - drift)
        samples[at] += (value - drift) * gain
    }
}

/// A message landing: two soft partials a fifth apart, the second a beat behind the
/// first. Tonal where a keystroke is not, so the two never sound like each other.
func chime(into samples: inout [Float], at start: Int, rate: Double) {
    for (frequency, delay, weight) in [(784.0, 0.0, Float(1)), (1176.0, 0.055, Float(0.62))] {
        let offset = Int(delay * rate)
        for index in 0..<Int(0.35 * rate) {
            let at = start + offset + index
            guard at >= 0, at < samples.count else { continue }
            let time = Double(index) / rate
            // Eased in over a few milliseconds, so it arrives rather than cracks.
            let attack = Float(min(1, time / 0.005))
            let fade = Float(exp(-time / 0.08))
            let tone = Float(sin(2 * .pi * frequency * time))
                + Float(sin(4 * .pi * frequency * time)) * 0.1
            samples[at] += tone * attack * fade * weight * 0.55
        }
    }
}

/// Writes `samples` as a 16-bit stereo file AVFoundation can put in a movie.
func write(_ samples: [Float], rate: Double, to url: URL) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
        fail("could not make an audio buffer")
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for channel in 0..<2 {
        guard let data = buffer.floatChannelData?[channel] else { continue }
        samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }
    }
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    try file.write(from: buffer)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        switch mode {
        case "sound":
            guard arguments.count == 5 else { fail("usage: scenario-video.swift sound MOVIE CUES STOPPED-AT") }
            let movie = URL(fileURLWithPath: arguments[2])
            guard let stopped = Double(arguments[4]) else { fail("\(arguments[4]) is not a time") }
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            // The recorder stops the moment it is told to, so the picture starts a
            // recording's length before that. Everything the app reported lines up from there.
            let started = stopped - seconds
            let cues: [(String, Double)] = (try String(contentsOf: URL(fileURLWithPath: arguments[3]), encoding: .utf8))
                .split(separator: "\n")
                .compactMap { line in
                    let fields = line.split(separator: " ")
                    guard fields.count == 2, let at = Double(fields[1]) else { return nil }
                    return (String(fields[0]), at - started)
                }
                .filter { $0.1 >= 0 && $0.1 < seconds }
            guard !cues.isEmpty else { print("no sounds to lay down"); semaphore.signal(); return }

            let rate = 44_100.0
            var samples = [Float](repeating: 0, count: Int(seconds * rate) + Int(rate * 0.4))
            for (name, at) in cues {
                let index = Int(at * rate)
                if name == "reply" { chime(into: &samples, at: index, rate: rate) }
                else { strike(into: &samples, at: index, rate: rate) }
            }
            quieten(&samples)

            let track = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("scenario-\(UUID().uuidString).wav")
            try write(samples, rate: rate, to: track)
            defer { try? FileManager.default.removeItem(at: track) }

            let composition = AVMutableComposition()
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                fail("\(movie.lastPathComponent) has no video")
            }
            try picture.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            picture.preferredTransform = try await source.load(.preferredTransform)
            let keys = AVURLAsset(url: track)
            if let sourceAudio = try await keys.loadTracks(withMediaType: .audio).first,
               let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let length = min(try await keys.load(.duration), duration)
                try audio.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: sourceAudio, at: .zero)
            }
            // Passthrough: the picture is copied across rather than encoded again.
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                fail("could not start an export")
            }
            let finished = movie.deletingLastPathComponent()
                .appendingPathComponent("\(movie.deletingPathExtension().lastPathComponent)-sound.mov")
            try? FileManager.default.removeItem(at: finished)
            try await export.export(to: finished, as: .mov)
            _ = try FileManager.default.replaceItemAt(movie, withItemAt: finished)
            print("\(cues.count) keystrokes in \(movie.path)")

        case "frame":
            guard arguments.count == 6 else { fail("usage: scenario-video.swift frame INPUT OUTPUT W:H black|white") }
            let input = URL(fileURLWithPath: arguments[2]), output = URL(fileURLWithPath: arguments[3])
            let parts = arguments[4].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { fail("\(arguments[4]) is not an aspect ratio like 16:9") }
            let (ratioWidth, ratioHeight) = (parts[0], parts[1])
            guard ["black", "white"].contains(arguments[5]) else { fail("the background is black or white") }
            let light = arguments[5] == "white"

            let asset = AVURLAsset(url: input)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("\(input.lastPathComponent) has no video") }
            let natural = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
            let source = CGSize(width: abs(natural.width), height: abs(natural.height))

            // The recording already frames the window; this only grows it to the asked-for shape.
            var canvas = source.width / source.height > ratioWidth / ratioHeight
                ? CGSize(width: source.width, height: source.width * ratioHeight / ratioWidth)
                : CGSize(width: source.height * ratioWidth / ratioHeight, height: source.height)
            // Deliver at a sensible size rather than whatever the display happened to give.
            let scale = min(1, 1920 / max(canvas.width, canvas.height))
            canvas = CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
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

        case "preview":
            guard arguments.count == 5, let count = Int(arguments[3]), let interval = Double(arguments[4]) else {
                fail("usage: scenario-video.swift preview OUT.wav KEYS INTERVAL")
            }
            let rate = 44_100.0
            var samples = [Float](repeating: 0, count: Int((Double(count + 2) * interval * 2 + 1.5) * rate))
            var at = 0.35
            for _ in 0..<count {
                strike(into: &samples, at: Int(at * rate), rate: rate)
                at += interval * Double.random(in: 0.55...1.65)
            }
            // The reply that follows, so both sounds can be judged together.
            at += 0.7
            chime(into: &samples, at: Int(at * rate), rate: rate)
            at += 0.5
            quieten(&samples)
            try write(samples, rate: rate, to: URL(fileURLWithPath: arguments[2]))
            print(String(format: "%d keys over %.1fs in %@", count, at, arguments[2]))

        default:
            fail("\(mode) is not frame, sound or preview")
        }
        semaphore.signal()
    } catch {
        fail(error.localizedDescription)
    }
}
semaphore.wait()
