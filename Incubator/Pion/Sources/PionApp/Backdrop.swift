import AppKit
import Metal
import QuartzCore
import SwiftUI

/// What moves behind the frosted window, chosen in View › Background. Every effect is
/// monochrome and quiet enough to read over, and holds still when the person asks for less motion.
enum BackdropEffect: String, CaseIterable, Identifiable {
    // The order is the shader's: each case's index picks its drawing.
    case none, glyphs, grid, scanlines, network, chess, chase

    static let key = "PionBackdropEffect"
    /// What View › Background offers, in its order. Scanlines, Chess and Chase are kept but not offered.
    static let offered: [BackdropEffect] = [.none, .grid, .network, .glyphs]
    /// What a new Pion starts with: nothing moving until the person picks an effect. Scenarios set their own.
    static let standard = BackdropEffect.none
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .glyphs: "Glyphs"
        case .grid: "Grid"
        case .scanlines: "Scanlines"
        case .network: "Network"
        case .chess: "Chess"
        case .chase: "Chase"
        }
    }
}

/// The window's backdrop. A render thread of its own draws each frame with Metal, so animating it
/// costs the main thread nothing; it holds still while the window is in the background or less
/// motion is asked for. Frosted, it goes behind the sidebar and inspector: the same picture, in
/// step with the one beside it, blurred and fainter, as if seen through their glass.
struct Backdrop: View {
    var frosted = false
    @AppStorage(BackdropEffect.key) private var effect = BackdropEffect.standard.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let kind = BackdropEffect(rawValue: effect) ?? .standard
        if kind != .none {
            BackdropLayerView(effect: kind, dark: colorScheme == .dark, moving: !reduceMotion && appearsActive, frosted: frosted)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct BackdropLayerView: NSViewRepresentable {
    let effect: BackdropEffect
    let dark: Bool
    let moving: Bool
    let frosted: Bool

    func makeNSView(context: Context) -> BackdropRenderView { BackdropRenderView(frosted: frosted) }

    func updateNSView(_ view: BackdropRenderView, context: Context) {
        view.renderer?.configure(effect: effect, dark: dark, moving: moving)
    }

    static func dismantleNSView(_ view: BackdropRenderView, coordinator: ()) { view.renderer?.stop() }
}

/// Hosts the Metal layer and tells the renderer where in its window it is and whether it is on screen.
final class BackdropRenderView: NSView {
    private let metalLayer = CAMetalLayer()
    private let frosted: Bool
    let renderer: BackdropRenderer?
    private var frameObserver: NSObjectProtocol?

    init(frosted: Bool) {
        self.frosted = frosted
        renderer = BackdropRenderer(layer: metalLayer, frosted: frosted)
        super.init(frame: .zero)
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Few pixels, stretched smoothly: the blur of frosted glass, at a fraction of the cost.
        metalLayer.magnificationFilter = .linear
        // Frames are presented as the render thread makes them, never with the main thread's transaction.
        metalLayer.presentsWithTransaction = false
        layer = metalLayer
        wantsLayer = true
        postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resize() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }

    override func layout() {
        super.layout()
        resize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resize()
        renderer?.setVisible(window != nil, window: window.map { ObjectIdentifier($0) })
    }

    private func resize() {
        guard let window, let content = window.contentView else { return }
        let scale = window.backingScaleFactor
        // Where this view sits in the window, from its top left, so every piece of the backdrop lines up.
        let frame = convert(bounds, to: nil)
        let origin = CGPoint(x: frame.minX, y: content.bounds.height - frame.maxY)
        let pixels = frosted ? 1.0 / 10 : scale
        metalLayer.contentsScale = scale
        renderer?.resize(bounds.size, pixels: pixels, origin: origin, canvas: content.bounds.size)
    }
}

/// What every piece of one window's backdrop shares: the clock, and the game being played.
final class BackdropWorld: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var worlds: [ObjectIdentifier: BackdropWorld] = [:]

    static func world(for window: ObjectIdentifier) -> BackdropWorld {
        lock.lock(); defer { lock.unlock() }
        if let world = worlds[window] { return world }
        let world = BackdropWorld()
        worlds[window] = world
        return world
    }

    private let lock = NSLock()
    private var clock = 0.0
    private var lastTick: Double?
    private var chess = ChessReplay()
    private var maze = MazeGame()
    private var game = GameUniforms()

    /// Moves time on by what passed since any piece last asked, while moving, and says what to draw.
    func frame(_ effect: BackdropEffect, canvas: CGSize, moving: Bool) -> (time: Double, game: GameUniforms, cells: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        // Never more than a tenth of a second at once, so a window coming back does not leap ahead.
        let elapsed = moving ? min(0.1, now - (lastTick ?? now)) : 0
        lastTick = moving ? now : nil
        clock += elapsed
        var cells: [UInt8] = [0]
        switch effect {
        case .chess:
            chess.advance(by: elapsed, into: &game)
            cells = chess.board
        case .chase:
            game.cell = 26
            maze.fit(width: Int((canvas.width / 26).rounded(.up)), height: Int((canvas.height / 26).rounded(.up)))
            maze.advance(by: elapsed, into: &game)
            cells = maze.cells
        default: break
        }
        return (clock.truncatingRemainder(dividingBy: 86_400), game, cells)
    }
}

/// Draws the backdrop from a timer on its own queue. Settings arrive from the main thread under a lock.
final class BackdropRenderer: @unchecked Sendable {
    /// Laid out as BackdropUniforms in Backdrop.metal.
    struct Uniforms {
        var size: SIMD2<Float>
        var scale: Float
        var time: Float
        var ink: SIMD4<Float>
        var effect: Int32
        var origin: SIMD2<Float>
        var strength: Float
    }

    private struct State {
        var effect = BackdropEffect.none
        var dark = true
        var moving = false
        var visible = false
        var window: ObjectIdentifier?
        var size = CGSize.zero
        var pixels: CGFloat = 2
        var origin = CGPoint.zero
        var canvas = CGSize.zero
    }

    private let layer: CAMetalLayer
    private let frosted: Bool
    private let queue = DispatchQueue(label: "Pion.backdrop", qos: .userInitiated)
    private let commands: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var state = State()
    private var timer: DispatchSourceTimer?
    private var interval: Double = 0

    init?(layer: CAMetalLayer, frosted: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "pionBackdropVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "pionBackdropFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        layer.device = device
        self.layer = layer
        self.frosted = frosted
        self.commands = commands
        self.pipeline = pipeline
    }

    func configure(effect: BackdropEffect, dark: Bool, moving: Bool) {
        update { $0.effect = effect; $0.dark = dark; $0.moving = moving }
    }

    func setVisible(_ visible: Bool, window: ObjectIdentifier?) { update { $0.visible = visible; $0.window = window } }

    func resize(_ size: CGSize, pixels: CGFloat, origin: CGPoint, canvas: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        layer.drawableSize = CGSize(width: max(1, (size.width * pixels).rounded(.up)), height: max(1, (size.height * pixels).rounded(.up)))
        update { $0.size = size; $0.pixels = pixels; $0.origin = origin; $0.canvas = canvas }
    }

    func stop() { update { $0.visible = false } }

    /// Applies a change, then on the render queue starts, retimes or stops the timer and draws once.
    private func update(_ change: (inout State) -> Void) {
        lock.lock(); change(&state); let current = state; lock.unlock()
        queue.async { [self] in
            // Glyphs step a row at a time, so a dozen frames suffice; the others move smoothly.
            let wanted = current.visible && current.moving && current.effect != .none ? (current.effect == .glyphs ? 1.0 / 12 : 1.0 / 30) : 0
            if wanted != interval {
                timer?.cancel(); timer = nil
                interval = wanted
                if wanted > 0 {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now(), repeating: wanted, leeway: .milliseconds(4))
                    timer.setEventHandler { [weak self] in self?.draw() }
                    timer.resume()
                    self.timer = timer
                }
            }
            if current.visible { draw() }
        }
    }

    private func draw() {
        lock.lock(); let current = state; lock.unlock()
        guard current.visible, current.effect != .none, current.size.width > 0, current.canvas.width > 0, let window = current.window,
              let drawable = layer.nextDrawable(), let buffer = commands.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let world = BackdropWorld.world(for: window).frame(current.effect, canvas: current.canvas, moving: interval > 0)
        var game = world.game
        let ink: Float = current.dark ? 1 : 0
        var uniforms = Uniforms(size: SIMD2(Float(current.canvas.width), Float(current.canvas.height)), scale: Float(current.pixels),
                                time: Float(world.time), ink: SIMD4(ink, ink, ink, 1),
                                effect: Int32(BackdropEffect.allCases.firstIndex(of: current.effect) ?? 0),
                                origin: SIMD2(Float(current.origin.x), Float(current.origin.y)),
                                // Kept well under the text; through frosted glass, softer and fainter still.
                                strength: frosted ? 0.3 : 0.6)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&game, length: MemoryLayout<GameUniforms>.stride, index: 1)
        // A large window's maze is past what setFragmentBytes takes, so it goes in a buffer of its own.
        if world.cells.count <= 4096 {
            encoder.setFragmentBytes(world.cells, length: world.cells.count, index: 2)
        } else if let cells = layer.device?.makeBuffer(bytes: world.cells, length: world.cells.count) {
            encoder.setFragmentBuffer(cells, offset: 0, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
