#if canImport(MetalKit) && canImport(SwiftUI)
import MetalKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Draws a Metal shader file live, behind a conversation or in its Quick Look preview. It draws at most
/// 30 frames a second and about a million pixels, stops while it can't be seen, and holds a still frame
/// with Reduce Motion or Low Power Mode.
@MainActor public final class ShaderCanvas: MTKView, MTKViewDelegate {
    public enum Status: Equatable { case loading, ready, failed(String) }

    /// The most pixels a frame has; larger views draw at a lower resolution and are scaled up.
    public static let maximumPixels: CGFloat = 1_200_000
    public static let framesPerSecond = 30

    public var onStatus: ((Status) -> Void)?
    public private(set) var status = Status.loading { didSet { if status != oldValue { onStatus?(status) } } }
    private var url: URL?
    private var pipeline: ShaderPipeline?
    private var queue: MTLCommandQueue?
    nonisolated(unsafe) private var loading: Task<Void, Never>?
    /// Seconds of animation shown so far; it stands still while paused, so the shader resumes where it was.
    private var elapsed: Double = 0
    private var lastFrame: CFTimeInterval?
    private var frameIndex: UInt32 = 0
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    public init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        delegate = self
        colorPixelFormat = ShaderPipeline.pixelFormat
        preferredFramesPerSecond = Self.framesPerSecond
        autoResizeDrawable = false
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        #if os(macOS)
        wantsLayer = true
        layer?.isOpaque = false
        #else
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        #endif
        isPaused = true
        enableSetNeedsDisplay = true
        queue = device?.makeCommandQueue()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePlayback() }
        })
        #if os(macOS)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePlayback() }
        })
        #else
        for name in [UIAccessibility.reduceMotionStatusDidChangeNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updatePlayback() }
            })
        }
        #endif
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        loading?.cancel()
        #if os(macOS)
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        #endif
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            #if os(macOS)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            #endif
        }
    }

    /// Shows the shader in `url`, compiling it off the main thread.
    public func show(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        pipeline = nil
        elapsed = 0
        frameIndex = 0
        status = .loading
        loading?.cancel()
        loading = Task { [weak self] in
            let result: Result<ShaderPipeline, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await ShaderPipeline.load(url)) } catch { return .failure(error) }
            }.value
            guard let self, !Task.isCancelled, self.url == url else { return }
            switch result {
            case .success(let pipeline):
                self.pipeline = pipeline
                self.status = .ready
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
            }
            self.updatePlayback()
        }
    }

    public func stop() {
        loading?.cancel()
        url = nil
        pipeline = nil
        isPaused = true
    }

    /// Whether frames should advance now: shown, on screen, and neither Reduce Motion nor Low Power Mode.
    var isLive: Bool {
        guard pipeline != nil, let window, bounds.width > 0, bounds.height > 0 else { return false }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        #if os(macOS)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized && !isHiddenOrHasHiddenAncestor
        #else
        if UIAccessibility.isReduceMotionEnabled { return false }
        return window.windowScene?.activationState != .background && !isHidden
        #endif
    }

    private func updatePlayback() {
        let live = isLive
        if !live { lastFrame = nil }
        enableSetNeedsDisplay = !live
        isPaused = !live
        if !live, pipeline != nil {
            // Held still at a moment past any fade in, rather than the first frame.
            if elapsed == 0 { elapsed = Double(ShaderPipeline.stillTime) }
            needsRedraw()
        }
    }

    private func needsRedraw() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    private func updateDrawableSize() {
        #if os(macOS)
        let scale = window?.backingScaleFactor ?? 2
        #else
        let scale = window?.screen.scale ?? traitCollection.displayScale
        #endif
        let points = bounds.width * bounds.height
        guard points > 0 else { return }
        let capped = min(scale, sqrt(Self.maximumPixels / points))
        let size = CGSize(width: max(1, (bounds.width * capped).rounded()), height: max(1, (bounds.height * capped).rounded()))
        if drawableSize != size { drawableSize = size; needsRedraw() }
    }

    #if os(macOS)
    public override func layout() { super.layout(); updateDrawableSize() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func viewDidHide() { super.viewDidHide(); updatePlayback() }
    public override func viewDidUnhide() { super.viewDidUnhide(); updatePlayback() }

    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didChangeBackingPropertiesNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.updateDrawableSize(); self?.updatePlayback() }
                })
            }
        }
        updateDrawableSize()
        updatePlayback()
    }
    #else
    public override func layoutSubviews() { super.layoutSubviews(); updateDrawableSize() }
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
        updatePlayback()
    }
    #endif

    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render() }
    }

    private func render() {
        guard let pipeline, let queue, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        if !isPaused {
            if let lastFrame { elapsed += min(now - lastFrame, 0.25) }
            lastFrame = now
            frameIndex &+= 1
        }
        let pointWidth = max(bounds.width, 1)
        pipeline.encode(encoder, frame: ShaderFrame(time: Float(elapsed), width: Float(drawableSize.width), height: Float(drawableSize.height),
                                                    scale: Float(drawableSize.width / pointWidth), index: frameIndex))
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

#if os(macOS)
/// A shader file drawn live, filling its frame. It ignores input.
public struct ShaderBackground: NSViewRepresentable {
    let url: URL
    var onStatus: ((ShaderCanvas.Status) -> Void)?
    public init(url: URL, onStatus: ((ShaderCanvas.Status) -> Void)? = nil) { self.url = url; self.onStatus = onStatus }
    public func makeNSView(context: Context) -> ShaderCanvas { ShaderCanvas() }
    public func updateNSView(_ view: ShaderCanvas, context: Context) { view.onStatus = onStatus; view.show(url) }
    public static func dismantleNSView(_ view: ShaderCanvas, coordinator: ()) { view.stop() }
}
#else
/// A shader file drawn live, filling its frame. It ignores input.
public struct ShaderBackground: UIViewRepresentable {
    let url: URL
    var onStatus: ((ShaderCanvas.Status) -> Void)?
    public init(url: URL, onStatus: ((ShaderCanvas.Status) -> Void)? = nil) { self.url = url; self.onStatus = onStatus }
    public func makeUIView(context: Context) -> ShaderCanvas { ShaderCanvas() }
    public func updateUIView(_ view: ShaderCanvas, context: Context) { view.onStatus = onStatus; view.show(url) }
    public static func dismantleUIView(_ view: ShaderCanvas, coordinator: ()) { view.stop() }
}
#endif

/// A shader file as its preview shows it: playing, or the reason it can't, in the compiler's words.
public struct ShaderPreview: View {
    let url: URL
    @State private var status = ShaderCanvas.Status.loading
    public init(url: URL) { self.url = url }

    public var body: some View {
        ZStack {
            Color.black
            ShaderBackground(url: url) { status = $0 }
            switch status {
            case .loading: ProgressView().controlSize(.small)
            case .ready: EmptyView()
            case .failed(let message):
                ScrollView {
                    Text(message)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        }
    }
}
#endif
