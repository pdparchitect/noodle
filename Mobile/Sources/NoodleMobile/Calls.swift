import AVFoundation
import HubLink
import SwiftUI
import UIKit
import WebKit

/// A call's channel to the Hub, which runs the bot, keeps the call's card and hears what is typed meanwhile.
protocol CallChannel: AnyObject {
    var frames: AsyncThrowingStream<Data, Error> { get }
    func cancel()
}

extension LinkChannel: CallChannel {}

/// Captures the microphone and plays the bot's voice for one call. The audio goes between the
/// phone and the bot's voice service, never through the Hub.
@MainActor protocol CallAudio: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    func prepareOffer() async throws -> String
    func accept(answer: String) async throws
    func setMuted(_ muted: Bool)
    func setSpeaker(_ on: Bool)
    func announceConnected()
    func close()
}

/// One call at a time on this Hub: starting another hangs up the current one.
@MainActor @Observable final class PhoneCalls {
    struct Call: Equatable {
        let id = UUID()
        let threadID: UUID
        let conversationID: UUID
        /// Nil while connecting.
        var startedAt: Date?
        var isMuted = false
        var isSpeaker = false
        var lines: [LinkCallLine] = []
    }

    private(set) var call: Call?
    /// Why the last call ended, when it went wrong.
    var problem: String?
    @ObservationIgnored private let open: @MainActor (LinkCallStart) async throws -> any CallChannel
    @ObservationIgnored private let makeAudio: @MainActor () -> any CallAudio
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var channel: (any CallChannel)?
    @ObservationIgnored private var audio: (any CallAudio)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(open: @escaping @MainActor (LinkCallStart) async throws -> any CallChannel,
         makeAudio: @escaping @MainActor () -> any CallAudio = { WebCallAudio() }, now: @escaping () -> Date = Date.init) {
        self.open = open
        self.makeAudio = makeAudio
        self.now = now
    }

    func start(threadID: UUID, conversationID: UUID) {
        hangUp()
        problem = nil
        let call = Call(threadID: threadID, conversationID: conversationID)
        let audio = makeAudio()
        self.call = call
        self.audio = audio
        audio.onFailure = { [weak self] in self?.end(call.id, problem: $0) }
        task = Task { [weak self] in
            do {
                let offer = try await audio.prepareOffer()
                guard let self, self.call?.id == call.id else { return }
                let channel = try await self.open(LinkCallStart(conversationID: conversationID, offer: offer))
                guard self.call?.id == call.id else { return channel.cancel() }
                self.channel = channel
                for try await frame in channel.frames {
                    guard let event = LinkCallEvent(frame) else { continue }
                    await self.handle(event, of: call.id)
                }
                self.end(call.id, problem: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.end(call.id, problem: error.localizedDescription)
            }
        }
    }

    func hangUp() {
        guard let call else { return }
        end(call.id, problem: nil)
    }

    func toggleSpeaker() {
        guard call != nil else { return }
        call?.isSpeaker.toggle()
        audio?.setSpeaker(call?.isSpeaker ?? false)
    }

    func toggleMute() {
        guard call != nil else { return }
        call?.isMuted.toggle()
        audio?.setMuted(call?.isMuted ?? false)
    }

    private func handle(_ event: LinkCallEvent, of id: UUID) async {
        guard call?.id == id else { return }
        switch event {
        case .answer(let sdp):
            do { try await audio?.accept(answer: sdp) }
            catch { end(id, problem: error.localizedDescription) }
        case .started:
            guard call?.startedAt == nil else { return }
            call?.startedAt = now()
            audio?.announceConnected()
        case .line(let line):
            call?.lines.append(line)
        case .ended(let detail):
            end(id, problem: detail)
        }
    }

    private func end(_ id: UUID, problem: String?) {
        guard call?.id == id else { return }
        task?.cancel()
        task = nil
        channel?.cancel()
        channel = nil
        audio?.close()
        audio = nil
        call = nil
        if let problem { self.problem = problem }
    }
}

/// The shared call page in a web view kept in the window. Faded out, iOS would treat it as hidden
/// and slow it, and the bot's voice would come in bursts with gaps filled in; it stays opaque
/// to iOS but clear and empty.
///
/// iOS cancels echo only through its call voice processing, which narrows the bot's voice to a
/// phone line. A call therefore starts on the earpiece, which the microphone barely hears, with
/// that processing off and the voice at full quality; the loudspeaker needs it on.
@MainActor final class WebCallAudio: NSObject, CallAudio, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onFailure: ((String) -> Void)?
    private var webView: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?

    func prepareOffer() async throws -> String {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw LinkError("Microphone access is off. Allow Noodle in Settings → Privacy & Security → Microphone.")
        }
        // Set once before the microphone starts and left alone: changed under a running microphone,
        // the session silences it. With processing off WebKit plays on the earpiece.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "call")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(webView)
        self.webView = webView
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            webView.loadHTMLString(LinkCallMedia.page, baseURL: LinkCallMedia.baseURL)
        }
        guard let offer = try await webView.callAsyncJavaScript("return await offer(false)", contentWorld: .page) as? String else {
            throw LinkError("The call could not start.")
        }
        return offer
    }

    /// The earpiece, or headphones and AirPods when connected, play the voice as it is; the
    /// loudspeaker needs echo cancellation, which comes with call voice processing.
    private static func setUp(speaker: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if speaker {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        } else {
            // A2DP plays AirPods at full quality while the phone's microphone listens.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        }
        try session.setActive(true)
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    /// Changing the session under a running microphone silences it, so the microphone stops first
    /// and starts again, with echo cancellation only for the loudspeaker, once the session is set.
    private func route(speaker: Bool) async throws {
        guard let webView else { return }
        _ = try await webView.callAsyncJavaScript("stopMicrophone(); return true", contentWorld: .page)
        try Self.setUp(speaker: speaker)
        _ = try await webView.callAsyncJavaScript("await startMicrophone(on); return true", arguments: ["on": speaker], contentWorld: .page)
        // Starting it makes WebKit set the session up again.
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
        _ = try await webView.callAsyncJavaScript("await context.resume(); return true", contentWorld: .page)
    }

    func accept(answer: String) async throws {
        _ = try await webView?.callAsyncJavaScript("await answer(sdp); return true", arguments: ["sdp": answer], contentWorld: .page)
    }

    func setMuted(_ muted: Bool) { webView?.evaluateJavaScript("mute(\(muted))") }

    func setSpeaker(_ on: Bool) {
        Task { [weak self] in
            do { try await self?.route(speaker: on) } catch { self?.onFailure?(error.localizedDescription) }
        }
    }

    func announceConnected() { webView?.evaluateJavaScript("chime()") }

    func close() {
        webView?.evaluateJavaScript("hangUp()")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "call")
        webView?.removeFromSuperview()
        webView = nil
        finishLoading(LinkError("The call ended."))
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard (message.body as? [String: Any])?["failed"] != nil, webView != nil else { return }
        onFailure?("The call connection was lost.")
    }

    private func finishLoading(_ error: Error?) {
        guard let loading else { return }
        self.loading = nil
        if let error { loading.resume(throwing: error) } else { loading.resume() }
    }
}

/// One stretch of a call between two messages.
struct CallBlock: Equatable {
    let botID: UUID
    var lines: [LinkCallLine]
    let isLive: Bool
}

enum CallLayout {
    /// Each spoken line goes after the last message sent before it was said, but never above its
    /// own call, so messages sent during a call split its transcript into blocks.
    static func blocks(in messages: [LinkMessage], live: (messageID: UUID, lines: [LinkCallLine])?) -> [UUID: CallBlock] {
        var placed: [UUID: CallBlock] = [:]
        for (index, card) in messages.enumerated() {
            guard let record = card.call else { continue }
            let isLive = live?.messageID == card.id
            for line in isLive ? live?.lines ?? [] : record.lines {
                var host = index
                if let at = line.at {
                    while host + 1 < messages.count, messages[host + 1].createdAt <= at { host += 1 }
                }
                placed[messages[host].id, default: CallBlock(botID: record.botID, lines: [], isLive: isLive)].lines.append(line)
            }
        }
        return placed
    }

    /// Elapsed time in a slot as wide as "00:00", so the bar never moves.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }
}

/// While this conversation is on a call: its time, Mute and End, over the conversation, which stays usable.
struct CallBar: View {
    let calls: PhoneCalls
    let call: PhoneCalls.Call

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "phone.fill")
                .foregroundStyle(call.startedAt == nil ? Color.secondary : Color.green)
            ZStack(alignment: .leading) {
                Text("00:00").hidden()
                if let startedAt = call.startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(CallLayout.elapsed(context.date.timeIntervalSince(startedAt)))
                    }
                } else {
                    Text("--:--")
                }
            }
            .monospacedDigit()
            .accessibilityLabel(call.startedAt == nil ? "Connecting" : "On a call")
            Spacer()
            Button { calls.toggleSpeaker() } label: {
                Image(systemName: call.isSpeaker ? "speaker.wave.3.fill" : "speaker.fill").frame(width: 28)
            }
            .tint(call.isSpeaker ? .accentColor : .primary)
            .accessibilityLabel("Speaker")
            .accessibilityAddTraits(call.isSpeaker ? .isSelected : [])
            Button { calls.toggleMute() } label: {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill").frame(width: 24)
            }
            .accessibilityLabel(call.isMuted ? "Unmute" : "Mute")
            Button(role: .destructive) { calls.hangUp() } label: {
                Image(systemName: "phone.down.fill").frame(width: 24)
            }
            .tint(.red)
            .accessibilityLabel("End Call")
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

/// Where a call starts in its conversation: live while it runs, then its length.
struct CallCardRow: View {
    let name: String
    let message: LinkMessage
    let record: LinkCallRecord
    let live: PhoneCalls.Call?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: live == nil ? "phone" : "phone.fill")
                .foregroundStyle(live == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Voice call with \(name)").font(.subheadline.weight(.medium))
                Group {
                    if let startedAt = live?.startedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(CallLayout.elapsed(context.date.timeIntervalSince(startedAt))).monospacedDigit()
                        }
                    } else if let endedAt = record.endedAt {
                        Text(Duration.seconds(max(0, endedAt.timeIntervalSince(message.createdAt)))
                            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity)
    }
}

/// A stretch of what was said on a call, kept to a two-line preview. Tapping it shows all of it.
struct CallBlockRow: View {
    let name: String
    let block: CallBlock
    @State private var showsAll = false

    var body: some View {
        // A live block follows the conversation; a finished one reads from its start.
        let preview = block.isLive ? Array(block.lines.suffix(2)) : Array(block.lines.prefix(2))
        Button { showsAll = true } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, line in
                        (Text(speaker(line) + "  ").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            + Text(line.text).font(.subheadline))
                            .lineLimit(1)
                    }
                    if block.lines.count > preview.count {
                        Text("\(block.lines.count) lines").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .accessibilityHint("Shows what was said")
        .sheet(isPresented: $showsAll) {
            NavigationStack {
                List(Array(block.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker(line)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(line.text).textSelection(.enabled)
                    }
                }
                .navigationTitle("Call")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsAll = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func speaker(_ line: LinkCallLine) -> String { line.speaker == .you ? "You" : name }
}

/// A short sample of each harness voice, shipped with the app, so choosing needs no call.
enum VoiceSample {
    static func url(provider: String, voice: String) -> URL? {
        Bundle.main.url(forResource: "\(provider)-\(voice)", withExtension: "m4a", subdirectory: "VoicePreviews")
    }
}

/// A bot's voice: tapping one chooses it and plays its sample, so voices can be compared.
struct VoicePicker: View {
    let provider: String
    let voices: [LinkCallVoice]
    @Binding var selection: String?
    @State private var player: AVAudioPlayer?
    @State private var playing: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Feminine", .feminine)
                group("Masculine", .masculine)
            }
            .padding()
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player?.stop() }
    }

    private func group(_ title: String, _ presentation: LinkCallVoice.Presentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(voices.filter { $0.presentation == presentation }) { voice in tile(voice) }
            }
        }
    }

    private func tile(_ voice: LinkCallVoice) -> some View {
        let isSelected = selection == voice.id
        return Button {
            selection = voice.id
            play(voice.id)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .symbolEffect(.variableColor.iterative, isActive: playing == voice.id)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(voice.name).font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.name)
        .accessibilityHint("Chooses this voice and plays a sample")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func play(_ voice: String) {
        player?.stop()
        playing = nil
        guard let url = VoiceSample.url(provider: provider, voice: voice), let next = try? AVAudioPlayer(contentsOf: url) else { return }
        // Heard with the ring switch on silent, as a voice someone asked to hear should be; a call
        // in progress keeps its own audio set-up.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback)
            try? session.setActive(true)
        }
        next.play()
        player = next
        playing = voice
        Task {
            try? await Task.sleep(for: .seconds(next.duration))
            if player === next { playing = nil }
        }
    }
}
