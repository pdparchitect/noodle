import AppKit
import AVFoundation
import NoodleAudioCapture

// Opt-in hardware check. Inspect buffer length/format only; never read samples,
// save recordings, transcribe speech, or open a conversation store.
private final class BufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        seconds += Double(buffer.frameLength) / buffer.format.sampleRate
    }
    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return seconds
    }
}

@main private enum VoiceStartupTest {
    @MainActor static func main() {
        setbuf(stdout, nil)
        guard CommandLine.arguments.contains("--live") else {
            print("SKIP: pass --live to activate the microphone for ten startup checks")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                print("FAIL: Microphone permission was not granted to the test app")
                exit(1)
            }
            do {
                let arguments = CommandLine.arguments
                let name = arguments.firstIndex(of: "--device-name").flatMap {
                    arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
                }
                let devices = VoiceInputDevice.available()
                let device: VoiceInputDevice
                if let name {
                    let matches = devices.filter { $0.name == name }
                    guard matches.count == 1 else { throw VoiceFailure("Expected exactly one microphone named \(name)") }
                    device = matches[0]
                } else {
                    device = try VoiceInputDevice.resolve(uid: "", devices: devices, defaultID: VoiceInputDevice.defaultDeviceID)
                }
                print("Testing \(device.name); counting buffers only")
                var failures = 0
                for attempt in 1...10 {
                    do { try await check(device: device, attempt: attempt) }
                    catch { failures += 1; print("FAIL attempt \(attempt): \(error.localizedDescription)") }
                    try await Task.sleep(for: .milliseconds(200))
                }
                print("\(failures == 0 ? "PASS" : "FAIL"): \(10 - failures)/10 microphone startup, continued capture, and stop checks")
                exit(failures == 0 ? 0 : 1)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor private static func check(device: VoiceInputDevice, attempt: Int) async throws {
        let engine = AVAudioEngine()
        _ = try VoiceInputDevice.configure(engine, uid: device.id)
        let native = NoodleAudioCapture(engine: engine)
        let counter = BufferCounter()
        var starts = 0
        let capture = VoiceCaptureRecovery(activate: {
            starts += 1
            try native.start(withBufferSize: 4096) { buffer, _ in counter.consume(buffer) }
        }, deactivate: { native.stop() }, running: { native.isRunning }, duration: { counter.duration })
        defer { capture.stop() }
        try await capture.start()
        let before = counter.duration
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(100))
            if !capture.isRunning { try await capture.start() }
        }
        guard capture.isRunning, counter.duration > before + 0.5 else {
            throw VoiceFailure("Microphone stopped delivering buffers after startup")
        }
        capture.stop()
        guard !capture.isRunning else { throw VoiceFailure("Microphone did not stop") }
        print("PASS attempt \(attempt): \(String(format: "%.2f", counter.duration)) seconds of buffers; \(starts) start(s)")
    }
}
