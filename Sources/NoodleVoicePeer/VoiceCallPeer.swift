import Foundation
import LiveKitWebRTC
import NoodleCore

/// One call's WebRTC connection to a harness's voice service. It has no microphone or speaker:
/// the person's voice comes in as samples, wherever it was captured, and the bot's goes out as
/// samples, wherever it is played. Audio is 48 kHz mono 16-bit throughout.
///
/// Echo cancellation and the like happen where the audio is captured, so the peer turns
/// WebRTC's own off.
public final class VoiceCallPeer: NSObject, VoiceCallPeering, @unchecked Sendable {
    public static let sampleRate = 48_000

    /// 10 ms at a time.
    public var onVoice: (@Sendable ([Int16]) -> Void)? {
        get { device.onVoice }
        set { device.onVoice = newValue }
    }
    public var onFailure: (@MainActor @Sendable () -> Void)?

    private let device = PCMAudioDevice()
    private let factory: LKRTCPeerConnectionFactory
    private var connection: LKRTCPeerConnection?
    private let gathered = GatheringWait()

    public override init() {
        Self.setUp
        factory = LKRTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: device)
        super.init()
    }

    private static let setUp: Void = { LKRTCInitializeSSL() }()

    /// The offer for the voice service, with every local address gathered, so it needs no
    /// further exchange.
    public func makeOffer() async throws -> String {
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw VoiceCallUnavailable()
        }
        self.connection = connection
        // The person's audio was processed where it was captured.
        let unprocessed = LKRTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "false", "googAutoGainControl": "false",
            "googNoiseSuppression": "false", "googHighpassFilter": "false"
        ], optionalConstraints: nil)
        let track = factory.audioTrack(with: factory.audioSource(with: unprocessed), trackId: "voice")
        connection.add(track, streamIds: ["call"])
        // The voice service sends its events on this channel; WebRTC needs it in the offer.
        _ = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration())
        let offer = try await connection.offer(for: LKRTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil))
        try await connection.setLocalDescription(offer)
        await gathered.wait(timeout: .seconds(3))
        guard let sdp = connection.localDescription?.sdp else { throw VoiceCallUnavailable() }
        return sdp
    }

    public func accept(answer: String) async throws {
        guard let connection else { throw VoiceCallUnavailable() }
        try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer))
    }

    public func hear(_ samples: [Int16]) { device.hear(samples) }

    public func close() {
        connection?.close()
        connection = nil
        device.stop()
        device.onVoice = nil
        gathered.finish()
    }
}

extension VoiceCallPeer: LKRTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { gathered.finish() }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        guard newState == .failed else { return }
        Task { @MainActor [weak self] in
            guard let self, self.connection === peerConnection else { return }
            self.onFailure?()
        }
    }
}

/// Resumes whoever waits once address gathering finishes, or at the timeout.
private final class GatheringWait: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait(timeout: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish()
        }
        defer { timer.cancel() }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if done { return true }
                waiting.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func finish() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            done = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }
}

/// WebRTC's audio device, run by a clock of its own rather than hardware: every 10 ms it hands
/// WebRTC the person's audio and takes the bot's. With nothing heard, it sends a faint noise
/// floor, as the voice model's clock only advances while audio arrives.
final class PCMAudioDevice: NSObject, LKRTCAudioDevice, @unchecked Sendable {
    static let chunk = VoiceCallPeer.sampleRate / 100
    /// Half a second of the person's voice at most; older audio is dropped to keep up.
    static let backlog = VoiceCallPeer.sampleRate / 2

    var onVoice: (@Sendable ([Int16]) -> Void)? {
        get { lock.withLock { voiceHandler } }
        set { lock.withLock { voiceHandler = newValue } }
    }

    private let lock = NSLock()
    private var voiceHandler: (@Sendable ([Int16]) -> Void)?
    private var heard: [Int16] = []
    private var delegate: LKRTCAudioDeviceDelegate?
    private var recording = false
    private var playing = false
    private var clock: Thread?

    func hear(_ samples: [Int16]) {
        lock.withLock {
            heard.append(contentsOf: samples)
            if heard.count > Self.backlog { heard.removeFirst(heard.count - Self.backlog) }
        }
    }

    func stop() {
        lock.withLock {
            recording = false
            playing = false
            clock?.cancel()
            clock = nil
        }
    }

    // MARK: LKRTCAudioDevice

    var deviceInputSampleRate: Double { Double(VoiceCallPeer.sampleRate) }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Double(VoiceCallPeer.sampleRate) }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { lock.withLock { delegate != nil } }
    var isPlayoutInitialized: Bool { isInitialized }
    var isRecordingInitialized: Bool { isInitialized }
    var isPlaying: Bool { lock.withLock { playing } }
    var isRecording: Bool { lock.withLock { recording } }

    func initialize(with delegate: LKRTCAudioDeviceDelegate) -> Bool {
        lock.withLock { self.delegate = delegate }
        return true
    }

    func terminateDevice() -> Bool {
        stop()
        lock.withLock { delegate = nil }
        return true
    }

    func initializePlayout() -> Bool { true }
    func initializeRecording() -> Bool { true }

    func startPlayout() -> Bool {
        lock.withLock { playing = true }
        startClock()
        return true
    }

    func stopPlayout() -> Bool {
        lock.withLock { playing = false }
        return true
    }

    func startRecording() -> Bool {
        lock.withLock { recording = true }
        startClock()
        return true
    }

    func stopRecording() -> Bool {
        lock.withLock { recording = false }
        return true
    }

    // MARK: Clock

    /// WebRTC wants its blocks called from one thread, so the clock is a thread, not a queue.
    private func startClock() {
        let thread = lock.withLock { () -> Thread? in
            guard clock == nil else { return nil }
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "Noodle voice call audio"
            thread.qualityOfService = .userInteractive
            clock = thread
            return thread
        }
        thread?.start()
    }

    private func run() {
        let interval = 1.0 / 100
        var next = Date().timeIntervalSinceReferenceDate
        var sampleTime = 0.0
        let input = UnsafeMutablePointer<Int16>.allocate(capacity: Self.chunk)
        let output = UnsafeMutablePointer<Int16>.allocate(capacity: Self.chunk)
        defer {
            input.deallocate()
            output.deallocate()
        }
        while !Thread.current.isCancelled {
            let (delegate, recording, playing, voice) = lock.withLock { () -> (LKRTCAudioDeviceDelegate?, Bool, Bool, (@Sendable ([Int16]) -> Void)?) in
                (self.delegate, self.recording, self.playing, voiceHandler)
            }
            guard let delegate else { break }
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = .sampleTimeValid
            if recording {
                fillHeard(input)
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(Self.chunk * 2), mData: input))
                var flags = AudioUnitRenderActionFlags()
                _ = delegate.deliverRecordedData(&flags, &timestamp, 1, UInt32(Self.chunk), &buffers, nil, nil)
            }
            if playing {
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(Self.chunk * 2), mData: output))
                var flags = AudioUnitRenderActionFlags()
                if delegate.getPlayoutData(&flags, &timestamp, 0, UInt32(Self.chunk), &buffers) == noErr {
                    voice?(Array(UnsafeBufferPointer(start: output, count: Self.chunk)))
                }
            }
            sampleTime += Double(Self.chunk)
            next += interval
            let wait = next - Date().timeIntervalSinceReferenceDate
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            } else if wait < -0.2 {
                // Far behind, as after the Mac slept: start the clock again from now.
                next = Date().timeIntervalSinceReferenceDate
            }
        }
    }

    private func fillHeard(_ buffer: UnsafeMutablePointer<Int16>) {
        let count = lock.withLock { () -> Int in
            let count = min(heard.count, Self.chunk)
            guard count > 0 else { return 0 }
            heard.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: count) }
            heard.removeFirst(count)
            return count
        }
        for index in count..<Self.chunk { buffer[index] = Int16.random(in: -60...60) }
    }
}
