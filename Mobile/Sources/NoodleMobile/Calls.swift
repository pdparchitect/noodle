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

/// The shared call page in a web view kept in the window, since WebKit does not run audio for a
/// web view that is not in one.
@MainActor final class WebCallAudio: NSObject, CallAudio, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onFailure: ((String) -> Void)?
    private var webView: WKWebView?
    private var loading: CheckedContinuation<Void, Error>?

    func prepareOffer() async throws -> String {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw LinkError("Microphone access is off. Allow Noodle in Settings → Privacy & Security → Microphone.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "call")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(webView)
        self.webView = webView
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            webView.loadHTMLString(LinkCallMedia.page, baseURL: LinkCallMedia.baseURL)
        }
        guard let offer = try await webView.callAsyncJavaScript("return await offer()", contentWorld: .page) as? String else {
            throw LinkError("The call could not start.")
        }
        return offer
    }

    func accept(answer: String) async throws {
        _ = try await webView?.callAsyncJavaScript("await answer(sdp); return true", arguments: ["sdp": answer], contentWorld: .page)
    }

    func setMuted(_ muted: Bool) { webView?.evaluateJavaScript("mute(\(muted))") }

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
