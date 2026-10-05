import AppKit
import AVFoundation
import Foundation
import NoodleCore
import NoodleRuntime
import WebKit
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor protocol VoiceCallRuntime: AnyObject {
    func startVoiceCall(agentID: UUID, _ request: VoiceCallRequest, events: @escaping @MainActor (VoiceCallEvent) -> Void) throws
    func sendToVoiceCall(agentID: UUID, _ text: String)
    func endVoiceCall(agentID: UUID)
}

extension AgentRuntimeCoordinator: VoiceCallRuntime {}

@MainActor protocol VoicePresentationGuessing {
    func presentation(forName name: String) async -> VoicePresentation?
}

/// Asks the on-device model, which knows names from many languages. Without Apple
/// Intelligence the harness's own default voice is used.
struct AppleVoicePresentationGuesser: VoicePresentationGuessing {
    func presentation(forName name: String) async -> VoicePresentation? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession()
        // The macOS 26 SDK used by CI predates the samplingMode label.
        #if canImport(FoundationModels, _version: 2)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 16)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 16)
        #endif
        // Offered "either", the model hedges even on names like Alfred, so it has to choose.
        let response = try? await session.respond(
            to: "People named \(name): are they more often women or men? Answer with the more common one.",
            generating: NamePresentation.self, options: options)
        return switch response?.content {
        case .woman: .feminine
        case .man: .masculine
        case nil: nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
private enum NamePresentation {
    case woman, man
}
#endif

/// Captures the microphone and plays the bot's voice for one call.
@MainActor protocol VoiceCallMedia: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func prepareOffer() async throws -> String
    func accept(answer: String) async throws
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
    @ObservationIgnored private let runtime: any VoiceCallRuntime
    @ObservationIgnored private let makeMedia: @MainActor () -> any VoiceCallMedia
    @ObservationIgnored private let report: @MainActor (String) -> Void
    @ObservationIgnored private let record: @MainActor (Call) -> UUID?
    @ObservationIgnored private let finish: @MainActor (Call, UUID, Date) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var media: (any VoiceCallMedia)?

    init(runtime: any VoiceCallRuntime, makeMedia: @escaping @MainActor () -> any VoiceCallMedia,
         report: @escaping @MainActor (String) -> Void,
         record: @escaping @MainActor (Call) -> UUID? = { _ in nil },
         finish: @escaping @MainActor (Call, UUID, Date) -> Void = { _, _, _ in },
         now: @escaping () -> Date = Date.init) {
        self.runtime = runtime
        self.makeMedia = makeMedia
        self.report = report
        self.record = record
        self.finish = finish
        self.now = now
    }

    func start(agentID: UUID, conversationID: UUID, voice: String?, personName: String,
               recentLines: [VoiceCallLine], media: (any VoiceCallMedia)? = nil) {
        hangUp()
        let call = Call(agentID: agentID, conversationID: conversationID)
        let media = media ?? makeMedia()
        self.call = call
        self.media = media
        media.onFailure = { [weak self] in self?.end(call.id, failure: $0, stopRuntime: true) }
        Task { [weak self] in
            let offer: String
            do { offer = try await media.prepareOffer() } catch {
                self?.end(call.id, failure: error.localizedDescription, stopRuntime: false)
                return
            }
            guard let self, self.call?.id == call.id else { return }
            do {
                try runtime.startVoiceCall(agentID: agentID, VoiceCallRequest(
                    offer: offer, voice: voice, conversationID: conversationID,
                    personName: personName, recentLines: recentLines
                )) { [weak self] in self?.handle($0, of: call.id) }
            } catch {
                end(call.id, failure: error.localizedDescription, stopRuntime: false)
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
        runtime.sendToVoiceCall(agentID: call.agentID,
                                VoiceCallDocumentation.typedMessage(body: body, attachmentNames: attachmentNames))
    }

    private func handle(_ event: VoiceCallEvent, of id: UUID) {
        guard call?.id == id else { return }
        switch event {
        case .answer(let sdp):
            guard let media else { return }
            Task {
                do { try await media.accept(answer: sdp) }
                catch { end(id, failure: error.localizedDescription, stopRuntime: true) }
            }
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
        if stopRuntime { runtime.endVoiceCall(agentID: call.agentID) }
        if let messageID = call.messageID { finish(call, messageID, now()) }
        media?.close()
        media = nil
        self.call = nil
        if let failure { report(failure) }
    }
}

/// WebKit provides WebRTC, echo cancellation and playback. Its page lives in an
/// invisible window because WebKit suspends audio in a web view that is not on screen.
@MainActor final class WebRTCVoiceCallMedia: NSObject, VoiceCallMedia, WKNavigationDelegate, WKUIDelegate {
    var onFailure: ((String) -> Void)?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?

    func prepareOffer() async throws -> String {
        try await Self.requestMicrophone()
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(MessageRelay(self), name: "call")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = webView
        window.orderFrontRegardless()
        self.window = window
        self.webView = webView
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            webView.loadHTMLString(Self.page, baseURL: URL(string: "https://call.noodle.invalid/"))
        }
        guard let offer = try await webView.callAsyncJavaScript("return await offer()", contentWorld: .page) as? String else {
            throw VoiceCallUnavailable()
        }
        return offer
    }

    func accept(answer: String) async throws {
        _ = try await webView?.callAsyncJavaScript("await answer(sdp); return true", arguments: ["sdp": answer], contentWorld: .page)
    }

    func setMuted(_ muted: Bool) {
        webView?.evaluateJavaScript("mute(\(muted))")
    }

    func announceConnected() {
        webView?.evaluateJavaScript("chime()")
    }

    func close() {
        webView?.evaluateJavaScript("hangUp()")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "call")
        webView = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        finishLoading(VoiceCallUnavailable())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    /// Async form: the completion-handler form can stop matching WebKit's selector and deny the microphone.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        webView === self.webView && type == .microphone ? .grant : .deny
    }

    private func finishLoading(_ error: Error?) {
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) } else { loading.resume() }
    }

    fileprivate func received(_ body: Any) {
        guard (body as? [String: Any])?["failed"] != nil, webView != nil else { return }
        onFailure?("The call connection was lost.")
    }

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

    /// The content controller retains its handlers; the relay keeps the media releasable.
    private final class MessageRelay: NSObject, WKScriptMessageHandler {
        weak var media: WebRTCVoiceCallMedia?
        init(_ media: WebRTCVoiceCallMedia) { self.media = media }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body
            MainActor.assumeIsolated { media?.received(body) }
        }
    }

    // The voice model's clock only advances while audio arrives, and WebKit stops
    // sending on digital silence, so a faint noise floor keeps it flowing while muted.
    private static let page = """
    <!doctype html><html><body><audio id="voice" autoplay></audio><script>
    let peer, microphone, context, gain;
    async function offer() {
      microphone = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true}});
      context = new AudioContext();
      await context.resume();
      const destination = context.createMediaStreamDestination();
      gain = context.createGain();
      context.createMediaStreamSource(microphone).connect(gain).connect(destination);
      const noise = context.createBuffer(1, context.sampleRate * 2, context.sampleRate);
      const samples = noise.getChannelData(0);
      for (let i = 0; i < samples.length; i++) samples[i] = (Math.random() * 2 - 1) * 0.002;
      const floor = context.createBufferSource();
      floor.buffer = noise; floor.loop = true; floor.connect(destination); floor.start();
      peer = new RTCPeerConnection();
      destination.stream.getAudioTracks().forEach(track => peer.addTrack(track, destination.stream));
      peer.createDataChannel('oai-events');
      peer.ontrack = event => { const voice = document.getElementById('voice'); voice.srcObject = event.streams[0]; voice.play().catch(() => {}); };
      peer.onconnectionstatechange = () => { if (peer.connectionState === 'failed') window.webkit.messageHandlers.call.postMessage({failed: true}); };
      await peer.setLocalDescription(await peer.createOffer());
      await new Promise(resolve => {
        if (peer.iceGatheringState === 'complete') return resolve();
        peer.onicegatheringstatechange = () => { if (peer.iceGatheringState === 'complete') resolve(); };
        setTimeout(resolve, 3000);
      });
      return peer.localDescription.sdp;
    }
    async function answer(sdp) { await peer.setRemoteDescription({type: 'answer', sdp}); }
    function mute(muted) { if (gain) gain.gain.value = muted ? 0 : 1; }
    // Played on the speakers, not into the call, so the bot never hears it.
    function chime() {
      if (!context) return;
      const start = context.currentTime;
      [[660, 0], [880, 0.13]].forEach(([frequency, offset]) => {
        const tone = context.createOscillator(), level = context.createGain();
        tone.type = 'sine';
        tone.frequency.value = frequency;
        level.gain.setValueAtTime(0, start + offset);
        level.gain.linearRampToValueAtTime(0.18, start + offset + 0.02);
        level.gain.exponentialRampToValueAtTime(0.001, start + offset + 0.28);
        tone.connect(level).connect(context.destination);
        tone.start(start + offset);
        tone.stop(start + offset + 0.3);
      });
    }
    function hangUp() {
      if (peer) peer.close();
      if (microphone) microphone.getTracks().forEach(track => track.stop());
      if (context) context.close();
    }
    </script></body></html>
    """
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
