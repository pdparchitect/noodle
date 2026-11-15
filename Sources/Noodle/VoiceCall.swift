import AppKit
import AVFoundation
import Foundation
import SwiftUI
import HubLink
import NoodleAudioCapture
import NoodleCore
import NoodleRuntime
import NoodleVoicePeer
import os

@MainActor protocol VoiceCallRuntime: AnyObject {
    func startVoiceCall(agentID: UUID, _ request: VoiceCallRequest, events: @escaping @MainActor (VoiceCallEvent) -> Void) throws
    func sendToVoiceCall(agentID: UUID, _ text: String)
    func endVoiceCall(agentID: UUID)
}

extension AgentRuntimeCoordinator: VoiceCallRuntime {}

/// A call's channel to the Hub keeping its bot.
protocol VoiceCallChannel: AnyObject, Sendable {
    var frames: AsyncThrowingStream<Data, Error> { get }
    func send(_ payload: Data)
    func cancel()
}

extension LinkChannel: VoiceCallChannel {}

/// What a call is about, before it is connected.
struct VoiceCallSetup: Equatable {
    /// Nil leaves the voice to the harness.
    var voice: String?
    var conversationID: UUID
    var personName: String
    /// Nil for a bot on a Hub, which tells the voice itself.
    var identity: VoiceCallIdentity?
    var recentLines: [VoiceCallLine] = []
    /// Why the bot called, when the person answered a call it placed.
    var answeredCallReason: String?
    /// The call a bot on a Hub placed that this answers, for the Hub to stop it ringing.
    var answeredCallID: UUID?

    func request(offer: String) -> VoiceCallRequest {
        VoiceCallRequest(offer: offer, voice: voice, conversationID: conversationID, personName: personName,
                         identity: identity, recentLines: recentLines, answeredCallReason: answeredCallReason)
    }
}

/// Connects a call to its bot's voice. A bot on this Mac gets a WebRTC connection here to its
/// harness's voice service; a bot kept on a Hub is called through that Hub, which holds the
/// connection, and the audio goes over the link. Either way the person's voice goes in through
/// the function a call returns, and the bot's comes out into the call's playout.
@MainActor final class VoiceCallRouter {
    private let local: any VoiceCallRuntime
    private let isOnHub: @MainActor (UUID) -> Bool
    private let openHubCall: @MainActor (UUID, VoiceCallSetup) async throws -> any VoiceCallChannel
    private let makePeer: @MainActor () -> any VoiceCallPeering
    private var peers: [UUID: any VoiceCallPeering] = [:]
    private var channels: [UUID: any VoiceCallChannel] = [:]
    /// The latest call per bot; one that ended or was replaced while connecting stops there.
    private var attempts: [UUID: UUID] = [:]

    init(local: any VoiceCallRuntime, isOnHub: @escaping @MainActor (UUID) -> Bool,
         openHubCall: @escaping @MainActor (UUID, VoiceCallSetup) async throws -> any VoiceCallChannel,
         makePeer: @escaping @MainActor () -> any VoiceCallPeering = { VoiceCallPeer() }) {
        self.local = local
        self.isOnHub = isOnHub
        self.openHubCall = openHubCall
        self.makePeer = makePeer
    }

    func startVoiceCall(agentID: UUID, _ setup: VoiceCallSetup, playout: LinkCallPlayout,
                        events: @escaping @MainActor (VoiceCallEvent) -> Void) async throws -> @Sendable ([Int16]) -> Void {
        endVoiceCall(agentID: agentID)
        let attempt = UUID()
        attempts[agentID] = attempt
        return isOnHub(agentID)
            ? try await callHub(agentID, setup, playout: playout, attempt: attempt, events: events)
            : try await callHere(agentID, setup, playout: playout, attempt: attempt, events: events)
    }

    func sendToVoiceCall(agentID: UUID, _ text: String) {
        guard !isOnHub(agentID) else { return }
        local.sendToVoiceCall(agentID: agentID, text)
    }

    func endVoiceCall(agentID: UUID) {
        attempts[agentID] = nil
        channels.removeValue(forKey: agentID)?.cancel()
        guard let peer = peers.removeValue(forKey: agentID) else { return }
        peer.close()
        local.endVoiceCall(agentID: agentID)
    }

    private func callHere(_ agentID: UUID, _ setup: VoiceCallSetup, playout: LinkCallPlayout, attempt: UUID,
                          events: @escaping @MainActor (VoiceCallEvent) -> Void) async throws -> @Sendable ([Int16]) -> Void {
        let peer = makePeer()
        peer.onVoice = { playout.append($0) }
        peer.onFailure = { [weak self] in
            guard let self, attempts[agentID] == attempt else { return }
            endVoiceCall(agentID: agentID)
            events(.ended("The call connection was lost."))
        }
        peers[agentID] = peer
        do {
            try await peer.place({ offer, runtimeEvents in
                guard attempts[agentID] == attempt else { throw CancellationError() }
                try local.startVoiceCall(agentID: agentID, setup.request(offer: offer), events: runtimeEvents)
            }) { [weak self] event in
                guard let self, attempts[agentID] == attempt else { return }
                if case .ended = event {
                    attempts[agentID] = nil
                    peers.removeValue(forKey: agentID)?.close()
                }
                events(event)
            }
        } catch {
            if attempts[agentID] == attempt {
                attempts[agentID] = nil
                peers[agentID] = nil
            }
            peer.close()
            throw error
        }
        return { peer.hear($0) }
    }

    private func callHub(_ agentID: UUID, _ setup: VoiceCallSetup, playout: LinkCallPlayout, attempt: UUID,
                         events: @escaping @MainActor (VoiceCallEvent) -> Void) async throws -> @Sendable ([Int16]) -> Void {
        let encoder = try LinkCallEncoder(), decoder = try LinkCallDecoder()
        let channel = try await openHubCall(agentID, setup)
        guard attempts[agentID] == attempt else {
            channel.cancel()
            throw CancellationError()
        }
        channels[agentID] = channel
        let ended: @MainActor (String?) -> Void = { [weak self] detail in
            guard let self, attempts[agentID] == attempt else { return }
            attempts[agentID] = nil
            channels.removeValue(forKey: agentID)?.cancel()
            events(.ended(detail))
        }
        // The bot's voice is decoded as it arrives, off the main actor; only events go there.
        Task.detached {
            do {
                for try await frame in channel.frames {
                    if let packet = LinkCallAudio.packet(in: frame) {
                        if let samples = try? decoder.decode(packet) { playout.append(samples) }
                        continue
                    }
                    guard let event = LinkCallEvent(frame) else { continue }
                    switch event {
                    case .started: await events(.started)
                    case .line(let line): await events(.line(VoiceCallLine(line.speaker == .you ? .person : .bot, line.text, at: line.at)))
                    case .ended(let detail): await ended(detail); return
                    }
                }
                await ended(nil)
            } catch {
                await ended(error is CancellationError ? nil : error.localizedDescription)
            }
        }
        return { samples in
            for packet in (try? encoder.encode(samples)) ?? [] { channel.send(LinkCallAudio.frame(packet)) }
        }
    }
}

/// The person's end of a call: the microphone, and the speakers playing the bot's voice.
@MainActor protocol VoiceCallMedia: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    /// Where the bot's voice waits to be played.
    var playout: LinkCallPlayout { get }
    /// Asks for the microphone and starts listening and playing; what the person says goes to
    /// `hear`, 48 kHz mono, from the audio thread.
    func start(hear: @escaping @Sendable ([Int16]) -> Void) async throws
    func setMuted(_ muted: Bool)
    func close()
    /// Tells the person the call has connected.
    func announceConnected()
}

/// One call at a time across the app: starting another hangs up the current one.
@MainActor @Observable final class VoiceCallController {
    struct Call: Equatable {
        let id = UUID()
        let agentID: UUID
        let conversationID: UUID
        /// Nil while connecting.
        var startedAt: Date?
        var isMuted = false
        var lines: [VoiceCallLine] = []
        /// The call's card in its conversation, once it connected.
        var messageID: UUID?
    }

    private(set) var call: Call?
    @ObservationIgnored private let router: VoiceCallRouter
    @ObservationIgnored private let makeMedia: @MainActor () -> any VoiceCallMedia
    @ObservationIgnored private let report: @MainActor (String) -> Void
    @ObservationIgnored private let record: @MainActor (Call) -> UUID?
    @ObservationIgnored private let finish: @MainActor (Call, UUID, Date) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var media: (any VoiceCallMedia)?

    init(router: VoiceCallRouter, makeMedia: @escaping @MainActor () -> any VoiceCallMedia,
         report: @escaping @MainActor (String) -> Void,
         record: @escaping @MainActor (Call) -> UUID? = { _ in nil },
         finish: @escaping @MainActor (Call, UUID, Date) -> Void = { _, _, _ in },
         now: @escaping () -> Date = Date.init) {
        self.router = router
        self.makeMedia = makeMedia
        self.report = report
        self.record = record
        self.finish = finish
        self.now = now
    }

    func start(agentID: UUID, conversationID: UUID, voice: String?, personName: String, identity: VoiceCallIdentity? = nil,
               recentLines: [VoiceCallLine], answeredCallReason: String? = nil, answeredCallID: UUID? = nil, media: (any VoiceCallMedia)? = nil) {
        hangUp()
        let call = Call(agentID: agentID, conversationID: conversationID)
        let media = media ?? makeMedia()
        self.call = call
        self.media = media
        media.onFailure = { [weak self] in self?.end(call.id, failure: $0, stopRuntime: true) }
        let speaking = SpokenAudio()
        Task { [weak self] in
            // The microphone first: without it there is no call to place.
            do { try await media.start(hear: speaking.hear) } catch {
                self?.end(call.id, failure: error.localizedDescription, stopRuntime: false)
                return
            }
            guard let self, self.call?.id == call.id else { return }
            do {
                let send = try await router.startVoiceCall(
                    agentID: agentID, VoiceCallSetup(voice: voice, conversationID: conversationID, personName: personName,
                                                     identity: identity, recentLines: recentLines, answeredCallReason: answeredCallReason, answeredCallID: answeredCallID),
                    playout: media.playout) { [weak self] in self?.handle($0, of: call.id) }
                guard self.call?.id == call.id else { return }
                speaking.connect(send)
            } catch {
                guard self.call?.id == call.id else { return }
                end(call.id, failure: error is CancellationError ? nil : error.localizedDescription, stopRuntime: false)
            }
        }
    }

    func hangUp() {
        guard let call else { return }
        end(call.id, failure: nil, stopRuntime: true)
    }

    func toggleMute() {
        guard call != nil else { return }
        call?.isMuted.toggle()
        media?.setMuted(call?.isMuted ?? false)
    }

    /// The bot reads chat messages through its inbox; the voice hears about them here.
    func shared(in conversationID: UUID, body: String, attachmentNames: [String]) {
        guard let call, call.conversationID == conversationID else { return }
        router.sendToVoiceCall(agentID: call.agentID,
                               VoiceCallDocumentation.typedMessage(body: body, attachmentNames: attachmentNames))
    }

    private func handle(_ event: VoiceCallEvent, of id: UUID) {
        guard call?.id == id else { return }
        switch event {
        case .answer:
            break
        case .started:
            guard call?.startedAt == nil else { return }
            call?.startedAt = now()
            media?.announceConnected()
            // Only a call that connected gets its card in the conversation.
            if let current = call, current.messageID == nil { call?.messageID = record(current) }
        case .line(var line):
            line.at = line.at ?? now()
            call?.lines.append(line)
            if let count = call?.lines.count, count > 100 { call?.lines.removeFirst(count - 100) }
        case .ended(let detail):
            end(id, failure: detail, stopRuntime: false)
        }
    }

    private func end(_ id: UUID, failure: String?, stopRuntime: Bool) {
        guard let call, call.id == id else { return }
        if stopRuntime { router.endVoiceCall(agentID: call.agentID) }
        if let messageID = call.messageID { finish(call, messageID, now()) }
        media?.close()
        media = nil
        self.call = nil
        if let failure { report(failure) }
    }
}

/// Where what the person says goes: nowhere until the call is connected.
final class SpokenAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var send: (@Sendable ([Int16]) -> Void)?

    func connect(_ send: @escaping @Sendable ([Int16]) -> Void) { lock.withLock { self.send = send } }
    func hear(_ samples: [Int16]) { lock.withLock { send }?(samples) }
}

/// How a call's audio starts: one engine with voice processing when the devices allow it, else
/// the microphone and speakers apart. Some pairs of microphone and speakers refuse voice
/// processing, or one engine for both, as a headset's microphone with the display's speakers;
/// headphones need no echo cancellation. Trying voice processing can also switch a Bluetooth
/// headset into its call mode, and until that settles its formats are stale and starting fails,
/// so starting apart is tried a few times.
@MainActor enum VoiceCallAudioStart {
    static let attempts = 5

    static func run<Started>(audio: VoiceAudioQueue, processed: @escaping @Sendable () throws -> Started,
                             apart: @escaping @Sendable () throws -> Started,
                             wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) })
        async throws -> Started {
        let refusal: Error
        do { return try await audio.run(processed) } catch let error as VoiceAudioQueue.Unresponsive {
            throw error
        } catch { refusal = error }
        var failure = refusal
        for attempt in 0..<attempts {
            if attempt > 0 { try await wait() }
            do { return try await audio.run(apart) } catch let error as VoiceAudioQueue.Unresponsive {
                throw error
            } catch { failure = error }
        }
        // Core Audio's own errors mean nothing to the person; the log keeps them, the first included.
        let first = String(describing: refusal), last = String(describing: failure)
        log.error("Call audio did not start. With voice processing: \(first, privacy: .public); apart: \(last, privacy: .public)")
        // The microphone's own messages, as a disconnected one, already say what to do.
        if failure is VoiceFailure { throw failure }
        throw StartFailure()
    }

    private static let log = Logger(subsystem: "com.pdparchitect.noodle", category: "VoiceCall")

    struct StartFailure: LocalizedError {
        var errorDescription: String? {
            "The call could not use the microphone or speakers. Reconnect your headphones or choose another microphone in Settings → Conversation, then call again."
        }
    }
}

/// The microphone chosen for dictation, with the Mac's own voice processing cancelling the bot's
/// voice from it, as on a FaceTime call, and the bot's voice on the speakers.
@MainActor final class EngineVoiceCallMedia: VoiceCallMedia {
    var onFailure: ((String) -> Void)?
    let playout = LinkCallPlayout()
    private let audio = VoiceAudioQueue()
    private let microphone = MicrophoneTap()
    private var capture: NoodleAudioCapture?
    private var engine: AVAudioEngine?
    /// Plays the bot's voice when the microphone has an engine of its own.
    private var speakerEngine: AVAudioEngine?
    private var configurationObservers: [NSObjectProtocol] = []
    private var isClosed = false

    func start(hear: @escaping @Sendable ([Int16]) -> Void) async throws {
        try await Self.requestMicrophone()
        microphone.hear = hear
        let microphone = microphone, playout = playout
        let (engine, capture, speakerEngine) = try await VoiceCallAudioStart.run(audio: audio, processed: {
            let (engine, capture) = try Self.makeEngine(microphone: microphone, playout: playout)
            return (engine, capture, AVAudioEngine?.none)
        }, apart: {
            let speaker = try Self.makeSpeaker(playout: playout)
            let engine = AVAudioEngine()
            let capture = NoodleAudioCapture(engine: engine)
            do {
                _ = try VoiceInputDevice.configure(engine)
                try capture.start(withBufferSize: 960) { buffer, _ in microphone.deliver(buffer) }
            } catch {
                speaker.stop()
                throw error
            }
            return (engine, capture, AVAudioEngine?.some(speaker))
        })
        // Starting can take a while as a headset settles; a call hung up meanwhile stays closed.
        guard !isClosed else {
            audio.post {
                capture.stop()
                speakerEngine?.stop()
            }
            throw CancellationError()
        }
        self.engine = engine
        self.capture = capture
        self.speakerEngine = speakerEngine
        // A device change stops the engine, and voice processing reports one as it settles: start
        // listening again, in the new format. The speakers' own engine stops the same way.
        configurationObservers = [NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }]
        if let speakerEngine {
            configurationObservers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: speakerEngine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartSpeaker() }
            })
        }
    }

    private func restartSpeaker() {
        guard let speakerEngine else { return }
        Task { [weak self, audio] in
            do {
                try await audio.run {
                    guard !speakerEngine.isRunning else { return }
                    speakerEngine.prepare()
                    try speakerEngine.start()
                }
            } catch {
                guard let self, self.speakerEngine === speakerEngine else { return }
                self.onFailure?("The microphone or speakers changed and the call could not go on.")
            }
        }
    }

    private func restart() {
        guard let capture else { return }
        let microphone = microphone
        Task { [weak self, audio] in
            do {
                try await audio.run { try capture.start(withBufferSize: 960) { buffer, _ in microphone.deliver(buffer) } }
            } catch {
                guard let self, self.capture === capture else { return }
                self.onFailure?("The microphone or speakers changed and the call could not go on.")
            }
        }
    }

    /// Core Audio can block indefinitely, so this runs on the voice audio queue.
    /// One engine for both, with voice processing cancelling the bot's voice from the microphone.
    nonisolated private static func makeEngine(microphone: MicrophoneTap,
                                               playout: LinkCallPlayout) throws -> (AVAudioEngine, NoodleAudioCapture) {
        let engine = AVAudioEngine()
        // The chosen microphone before voice processing, which is set up for the devices in place
        // when it is enabled. Enabling it can bring back the system input; configuring again then
        // restores the chosen one, and does nothing when it stayed.
        _ = try VoiceInputDevice.configure(engine)
        try engine.inputNode.setVoiceProcessingEnabled(true)
        // Other apps' sound stays as it was.
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        _ = try VoiceInputDevice.configure(engine)
        attachVoice(playout, to: engine)
        let capture = NoodleAudioCapture(engine: engine)
        try capture.start(withBufferSize: 960) { buffer, _ in microphone.deliver(buffer) }
        return (engine, capture)
    }

    nonisolated private static func makeSpeaker(playout: LinkCallPlayout) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        attachVoice(playout, to: engine)
        engine.prepare()
        try engine.start()
        return engine
    }

    nonisolated private static func attachVoice(_ playout: LinkCallPlayout, to engine: AVAudioEngine) {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(LinkCallAudio.sampleRate), channels: 1)!
        let speaker = AVAudioSourceNode(format: format) { _, _, frameCount, buffers in
            let out = UnsafeMutableAudioBufferListPointer(buffers)[0]
            let samples = out.mData!.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)
            let voice = UnsafeMutableBufferPointer<Int16>.allocate(capacity: count)
            defer { voice.deallocate() }
            playout.read(into: voice)
            for index in 0..<count { samples[index] = Float(voice[index]) / 32_768 }
            return noErr
        }
        engine.attach(speaker)
        engine.connect(speaker, to: engine.mainMixerNode, format: format)
    }

    func setMuted(_ muted: Bool) { microphone.isMuted = muted }

    func announceConnected() { playout.append(Self.chime) }

    func close() {
        isClosed = true
        for observer in configurationObservers { NotificationCenter.default.removeObserver(observer) }
        configurationObservers = []
        microphone.hear = nil
        let capture = capture, speakerEngine = speakerEngine
        audio.post {
            capture?.stop()
            speakerEngine?.stop()
        }
        self.capture = nil
        self.speakerEngine = nil
        engine = nil
    }

    /// Two rising notes, played on the speakers only.
    private static let chime: [Int16] = {
        let rate = Double(LinkCallAudio.sampleRate)
        return (0..<Int(rate * 0.43)).map { index in
            let time = Double(index) / rate
            let sum = [(660.0, 0.0), (880.0, 0.13)].reduce(0.0) { sum, note in
                let local = time - note.1
                guard local >= 0, local < 0.3 else { return sum }
                let level = local < 0.02 ? local / 0.02 * 0.18 : 0.18 * pow(0.001 / 0.18, (local - 0.02) / 0.26)
                return sum + sin(2 * .pi * note.0 * local) * min(level, 0.18)
            }
            return Int16(max(-1, min(1, sum)) * 32_767)
        }
    }()

    private static func requestMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined: if await AVCaptureDevice.requestAccess(for: .audio) { return }
        default: break
        }
        throw MicrophoneUnavailable()
    }

    private struct MicrophoneUnavailable: LocalizedError {
        var errorDescription: String? {
            "Microphone access is off. Enable Noodle in System Settings → Privacy & Security → Microphone."
        }
    }
}

/// Turns the microphone's buffers, in whatever format the device gives, into the call's audio.
final class MicrophoneTap: @unchecked Sendable {
    private let lock = NSLock()
    private var _hear: (@Sendable ([Int16]) -> Void)?
    private var _muted = false
    private var converter: AVAudioConverter?
    private static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(LinkCallAudio.sampleRate),
                                              channels: 1, interleaved: true)!

    var hear: (@Sendable ([Int16]) -> Void)? {
        get { lock.withLock { _hear } }
        set { lock.withLock { _hear = newValue } }
    }

    var isMuted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    /// Called on the audio thread. Voice processing can hand over several channels; the first is the voice.
    func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let hear, !isMuted, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let rate = buffer.format.sampleRate
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
        input.frameLength = buffer.frameLength
        input.floatChannelData![0].update(from: channel, count: Int(buffer.frameLength))
        if converter?.inputFormat.sampleRate != rate { converter = AVAudioConverter(from: mono, to: Self.target) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Double(LinkCallAudio.sampleRate) / rate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        var given = false
        _ = converter.convert(to: output, error: nil) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return input
        }
        guard output.frameLength > 0 else { return }
        hear(Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength))))
    }
}

/// A short sample of each harness voice, recorded once and shipped with the app, so
/// choosing a voice needs neither a sign-in nor a call.
enum VoicePreview {
    static func fileName(provider: HarnessProvider, voice: String) -> String { "\(provider.rawValue)-\(voice).m4a" }

    static func url(provider: HarnessProvider, voice: String) -> URL? {
        Bundle.main.url(forResource: fileName(provider: provider, voice: voice), withExtension: nil, subdirectory: "VoicePreviews")
    }
}

/// Plays one preview at a time; starting another stops the current one.
@MainActor @Observable final class VoicePreviewPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playingVoice: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    /// Starts the sample from the beginning, even if it was already playing.
    func play(_ voice: String, provider: HarnessProvider) {
        stop()
        guard let url = VoicePreview.url(provider: provider, voice: voice),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playingVoice = voice
    }

    func stop() {
        player?.stop()
        player = nil
        playingVoice = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard player === self.player else { return }
            self.player = nil
            playingVoice = nil
        }
    }
}

/// The Voice row of a bot's harness settings, for a harness with voices: the chosen voice, and the chooser that
/// plays each one. Empty leaves the voice to the harness.
struct VoiceSelectionRow: View {
    let provider: HarnessProvider
    @Binding var selection: String
    @State private var choosing = false
    @State private var preview = VoicePreviewPlayer()

    var body: some View {
        Button { choosing = true } label: {
            RuntimeSelectionRow(title: "Voice", value: provider.voices.first { $0.id == selection }?.name ?? "\(provider.displayName) default",
                                icon: AnyView(Image(systemName: "waveform")))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $choosing, arrowEdge: .leading) {
            VoiceChooser(provider: provider, selection: $selection, preview: preview)
        }
    }
}

/// The voice a bot speaks with on calls. Choosing a voice plays its sample and keeps
/// the chooser open, so voices can be compared by clicking through them.
struct VoiceChooser: View {
    let provider: HarnessProvider
    @Binding var selection: String
    let preview: VoicePreviewPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Voice")
                .font(.headline)
            group("Feminine", .feminine)
            group("Masculine", .masculine)
        }
        .padding(16)
        .frame(width: 340)
        .onDisappear { preview.stop() }
    }

    private func group(_ title: String, _ presentation: VoicePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(provider.voices.filter { $0.presentation == presentation }, id: \.id) { voice in
                    tile(voice)
                }
            }
        }
    }

    private func tile(_ voice: HarnessVoice) -> some View {
        let isSelected = selection == voice.id, isPlaying = preview.playingVoice == voice.id
        return Button {
            selection = voice.id
            preview.play(voice.id, provider: provider)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 17))
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(voice.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Choose \(voice.name) and hear it")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
