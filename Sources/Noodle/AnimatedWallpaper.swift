import AppKit
import AVFoundation
import SwiftUI
import NoodleCore

/// Layer-backed playback never drives the transcript's SwiftUI layout.
struct AnimatedWallpaper: NSViewRepresentable {
    let url: URL
    let kind: BackgroundMediaKind
    let reduceMotion: Bool

    func makeNSView(context: Context) -> AnimatedWallpaperView { AnimatedWallpaperView() }
    func updateNSView(_ view: AnimatedWallpaperView, context: Context) {
        view.configure(url: url, kind: kind, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: AnimatedWallpaperView, coordinator: ()) { view.stop() }
}

@MainActor final class AnimatedWallpaperView: NSView {
    private var url: URL?
    private var kind: BackgroundMediaKind?
    private var reduceMotion = false
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    private let imageLayer = CALayer()
    private var frameTask: Task<Void, Never>?
    private var initialFrameTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private(set) var frameIndex = 0
    var completedLoops: Int { looper?.loopCount ?? 0 }
    private var generation = UUID()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.masksToBounds = true
        layer?.addSublayer(imageLayer)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(url: URL, kind: BackgroundMediaKind, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        if self.url != url || self.kind != kind {
            stopPlayback()
            self.url = url; self.kind = kind
            if kind == .video {
                let player = AVQueuePlayer()
                player.isMuted = true
                player.volume = 0
                player.preventsDisplaySleepDuringVideoPlayback = false
                let item = AVPlayerItem(asset: BackgroundMedia.videoAsset(at: url))
                self.player = player
                looper = AVPlayerLooper(player: player, templateItem: item)
                let videoLayer = AVPlayerLayer(player: player)
                videoLayer.videoGravity = .resizeAspectFill
                self.videoLayer = videoLayer
                layer?.addSublayer(videoLayer)
                needsLayout = true
            } else {
                initialFrameTask = Task { [weak self] in await self?.showFrame(0, fade: false) }
            }
        }
        updatePlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.updatePlayback() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.updatePlayback() }
                })
            }
        }
        updatePlayback()
    }

    private func updatePlayback() {
        let visible = window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false && !NSApp.isHidden
        let playing = visible && !reduceMotion
        // Reassert mute before every play, including returning from hidden state.
        player?.isMuted = true
        player?.volume = 0
        if playing { player?.play() } else { player?.pause() }
        if playing && kind == .dynamicImage {
            guard frameTask == nil else { return }
            frameTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    await self?.advanceFrame()
                }
            }
        } else {
            frameTask?.cancel(); frameTask = nil
        }
    }

    private func advanceFrame() async {
        guard let url else { return }
        let count = await Task.detached { BackgroundMedia.frameCount(at: url) }.value
        guard !Task.isCancelled, count > 1 else { return }
        await showFrame((frameIndex + 1) % count, fade: true)
    }

    private func showFrame(_ index: Int, fade: Bool) async {
        guard let url else { return }
        let request = generation
        let image = await Task.detached { BackgroundMedia.image(at: url, index: index) }.value
        guard !Task.isCancelled, request == generation else { return }
        frameIndex = index // Skip a damaged frame on the next tick, retaining the last readable image.
        guard let image else { return }
        if fade && !reduceMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 1
            imageLayer.add(transition, forKey: "wallpaper-frame")
        }
        imageLayer.contents = image
        frameIndex = index
    }

    func stop() {
        stopPlayback()
        removeObservers()
        url = nil; kind = nil
    }

    private func stopPlayback() {
        generation = UUID()
        frameTask?.cancel(); frameTask = nil
        initialFrameTask?.cancel(); initialFrameTask = nil
        player?.pause()
        looper?.disableLooping(); looper = nil
        player?.removeAllItems(); player = nil
        videoLayer?.player = nil
        videoLayer?.removeFromSuperlayer(); videoLayer = nil
        imageLayer.removeAllAnimations(); imageLayer.contents = nil
        frameIndex = 0
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
