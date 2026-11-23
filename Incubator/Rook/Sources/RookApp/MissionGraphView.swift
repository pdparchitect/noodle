import RookCore
import SwiftUI
import AppKit

/// A frosted case map. Selection focuses connections; dragging only changes this presentation.
struct MissionGraphView: View {
    let model: RookModel
    let mission: Mission
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var interaction = MissionGraphInteraction()
    @State private var selected: String?
    @State private var hovered: String?
    @State private var viewport = MissionGraphViewport()
    @State private var canvasSize = CGSize(width: 1, height: 1)
    @State private var pinchScale: CGFloat?

    var body: some View {
        let record = model.caseRecord(mission.id)
        ZStack {
            if record.entities.isEmpty {
                ContentUnavailableView("No graph yet", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Agents build it as they link what they find."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                graph(record)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .topTrailing) {
            Button { close() } label: {
                Image(systemName: "xmark.circle.fill").imageScale(.large)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help("Close the graph").padding(16)
        }
        .onChange(of: record.entities.map(\.id)) {
            if let selected, !record.entities.contains(where: { $0.id == selected }) { self.selected = nil }
        }
    }

    /// The parent proposes the available content area; the shared sheet sizing handles screen bounds.
    static func sheetSize(in parent: CGSize) -> CGSize {
        CGSize(width: max(1, parent.width - 96), height: max(1, parent.height - 96))
    }

    private func graph(_ record: CaseRecord) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                graphContent(record, in: canvasSize)
                    .frame(width: viewport.renderSize(canvasSize).width,
                           height: viewport.renderSize(canvasSize).height)
                    .background(MissionGraphMiddlePan(zoom: { viewport.zoom(by: $0) }))
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.center)
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    if pinchScale == nil { pinchScale = viewport.scale }
                    viewport.setScale((pinchScale ?? 1) * value.magnification)
                }
                .onEnded { _ in pinchScale = nil })
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 14) {
                    Button { viewport.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .keyboardShortcut("-", modifiers: .command).help("Zoom out")
                    Button { viewport.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .keyboardShortcut("+", modifiers: .command).help("Zoom in")
                    Button { viewport.fit(canvas: canvasSize, inside: geo.size) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .keyboardShortcut("0", modifiers: .command).help("Fit the graph")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(12).background(.regularMaterial, in: Capsule()).padding(14)
            }
            .onAppear { arrange(record, in: geo.size) }
            .onChange(of: geo.size) { _, size in arrange(record, in: size) }
            .onChange(of: record.entities.map(\.id)) { arrange(record, in: geo.size) }
            .onChange(of: record.links) { arrange(record, in: geo.size) }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selected)
        }
    }

    private func arrange(_ record: CaseRecord, in size: CGSize) {
        interaction.end()
        interaction.positions = Self.layout(record, in: size)
        canvasSize = CGSize(width: max(size.width, (interaction.positions.values.map(\.x).max() ?? 0) + 110),
                            height: max(size.height, (interaction.positions.values.map(\.y).max() ?? 0) + 100))
        viewport.fit(canvas: canvasSize, inside: size)
    }

    private func graphContent(_ record: CaseRecord, in size: CGSize) -> some View {
        let focus = record.graphFocus(around: selected)
        return ZStack {
            // The empty canvas remains transparent over the panel's original material.
            Color.clear.contentShape(Rectangle()).onTapGesture { selected = nil }
            // Draw into a canvas at the displayed dimensions. Scaling an already rendered canvas
            // magnifies its backing pixels; transforming drawing coordinates redraws at native resolution.
            Canvas { context, _ in
                var drawing = context
                drawing.scaleBy(x: viewport.scale, y: viewport.scale)
                for (index, link) in record.links.enumerated() {
                    guard let a = interaction.positions[link.from], let b = interaction.positions[link.to] else { continue }
                    let active = selected == nil || link.from == selected || link.to == selected
                    let color = record.entities.first(where: { $0.id == link.from }).map { Self.color($0.kind) } ?? .secondary
                    Self.drawEdge(drawing, from: a, to: b, bend: bend(link, index: index, record: record),
                                  color: color.opacity(active ? 0.65 : 0.08), emphasized: selected != nil && active)
                }
            }
            .allowsHitTesting(false)
            ForEach(Array(record.links.enumerated()), id: \.element.id) { index, link in
                if let a = interaction.positions[link.from], let b = interaction.positions[link.to] {
                    let active = selected == nil || link.from == selected || link.to == selected
                    Text(link.relation)
                        .font(.system(size: 10 * viewport.scale, weight: .medium))
                        .lineLimit(1).frame(maxWidth: 140 * viewport.scale)
                        .foregroundStyle(selected != nil && active ? .primary : .secondary)
                        .padding(.horizontal, 7 * viewport.scale).padding(.vertical, 3 * viewport.scale)
                        .background(.regularMaterial, in: Capsule())
                        .opacity(active ? 1 : 0.12)
                        .position(viewport.renderPosition(a == b ? CGPoint(x: a.x, y: a.y - 83)
                                  : Self.control(a, b, bend: bend(link, index: index, record: record) / 2)))
                        .allowsHitTesting(false)
                }
            }
            ForEach(record.entities) { entity in
                if let point = interaction.positions[entity.id] {
                    node(entity)
                        .opacity(focus.contains(entity.id) ? 1 : 0.22)
                        // Install the drag on the card before positioning it. A named coordinate space
                        // stays fixed while the card moves; convert the displayed pointer back to layout units.
                        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("missionGraph"))
                            .onChanged { value in
                                interaction.move(entity.id, start: value.startLocation, location: value.location, in: size, scale: viewport.scale)
                            }
                            .onEnded { _ in interaction.end() })
                        .position(viewport.renderPosition(point))
                }
            }
        }
        .coordinateSpace(name: "missionGraph")
    }

    private func node(_ entity: CaseRecord.Entity) -> some View {
        let color = Self.color(entity.kind)
        let active = selected == entity.id
        let scale = viewport.scale
        return Button { selected = active ? nil : entity.id } label: {
            HStack(spacing: 9 * scale) {
                Image(systemName: entity.kind.symbol)
                    .font(.system(size: 16 * scale, weight: .medium)).foregroundStyle(color)
                    .frame(width: 30 * scale, height: 32 * scale)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8 * scale))
                VStack(alignment: .leading, spacing: 4 * scale) {
                    Text(entity.kind.title.uppercased()).font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)
                    Text(entity.name).font(.system(size: 11 * scale, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
            }
            .padding(10 * scale).frame(width: 156 * scale, height: 64 * scale)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12 * scale))
            .overlay(RoundedRectangle(cornerRadius: 12 * scale).fill(color.opacity(active ? 0.12 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12 * scale).strokeBorder(color.opacity(active ? 1 : 0.4), lineWidth: (active ? 2 : 1) * scale))
            .shadow(color: color.opacity(active ? 0.25 : 0), radius: 16 * scale)
            .shadow(color: .black.opacity(0.15), radius: (hovered == entity.id ? 10 : 4) * scale, y: 3 * scale)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? entity.id : nil }
        .help(entity.detail ?? entity.name)
        .accessibilityLabel("\(entity.kind.title): \(entity.name)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // Parallel and reciprocal links get separate curves. Self-links use a loop above the card.
    private func bend(_ link: CaseRecord.Link, index: Int, record: CaseRecord) -> CGFloat {
        let siblings = record.links.prefix(index).filter { ($0.from == link.from && $0.to == link.to) || ($0.from == link.to && $0.to == link.from) }.count
        return CGFloat(24 + siblings * 32)
    }

    static func control(_ a: CGPoint, _ b: CGPoint, bend: CGFloat) -> CGPoint {
        let distance = max(1, hypot(b.x - a.x, b.y - a.y))
        return CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) / distance * bend,
                       y: (a.y + b.y) / 2 + (b.x - a.x) / distance * bend)
    }

    static func drawEdge(_ context: GraphicsContext, from a: CGPoint, to b: CGPoint,
                         bend: CGFloat, color: Color, emphasized: Bool) {
        var line = Path()
        if a == b {
            line.move(to: CGPoint(x: a.x - 28, y: a.y - 32))
            line.addCurve(to: CGPoint(x: a.x + 28, y: a.y - 32),
                          control1: CGPoint(x: a.x - 90, y: a.y - 100),
                          control2: CGPoint(x: a.x + 90, y: a.y - 100))
            context.stroke(line, with: .color(color), lineWidth: emphasized ? 2.5 : 1.5)
            var arrow = Path()
            arrow.move(to: CGPoint(x: a.x + 28, y: a.y - 32))
            arrow.addLine(to: CGPoint(x: a.x + 28, y: a.y - 42))
            arrow.addLine(to: CGPoint(x: a.x + 38, y: a.y - 35))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(color))
            return
        }
        let c = control(a, b, bend: bend)
        // Intersect the endpoint tangent with the card bounds rather than a fixed circular gap.
        func boundary(_ center: CGPoint, toward target: CGPoint) -> CGPoint {
            let dx = target.x - center.x, dy = target.y - center.y
            let scale = min(82 / max(abs(dx), 0.001), 36 / max(abs(dy), 0.001))
            return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
        }
        let start = boundary(a, toward: c), end = boundary(b, toward: c)
        guard hypot(b.x - a.x, b.y - a.y) > 100 else { return }
        line.move(to: start)
        line.addQuadCurve(to: end, control: c)
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: emphasized ? 2.5 : 1.5, lineCap: .round))
        let angle = atan2(end.y - c.y, end.x - c.x)
        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - cos(angle - 0.45) * 9, y: end.y - sin(angle - 0.45) * 9))
        arrow.addLine(to: CGPoint(x: end.x - cos(angle + 0.45) * 9, y: end.y - sin(angle + 0.45) * 9))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    static func color(_ kind: CaseRecord.Entity.Kind) -> Color {
        switch kind {
        case .host: .blue
        case .service: .teal
        case .account: .orange
        case .credential: .pink
        case .artifact: .purple
        case .other: .secondary
        }
    }

    /// Directed columns preserve card spacing rather than squeezing a force simulation into the
    /// viewport. Break cycles deterministically, order neighbours to reduce crossings, then pack
    /// disconnected components into shelves. The viewport fits the resulting canvas independently.
    static func layout(_ record: CaseRecord, in size: CGSize) -> [String: CGPoint] {
        let ids = record.entities.map(\.id)
        guard !ids.isEmpty else { return [:] }
        let known = Set(ids)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var outgoing: [String: Set<String>] = [:]
        var incoming: [String: Set<String>] = [:]
        var neighbours: [String: Set<String>] = [:]
        for link in record.links where link.from != link.to && known.contains(link.from) && known.contains(link.to) {
            outgoing[link.from, default: []].insert(link.to)
            incoming[link.to, default: []].insert(link.from)
            neighbours[link.from, default: []].insert(link.to)
            neighbours[link.to, default: []].insert(link.from)
        }
        func ordered(_ values: Set<String>) -> [String] { values.sorted { order[$0]! < order[$1]! } }
        var unseen = known
        var components: [[String]] = []
        for id in ids where unseen.contains(id) {
            var queue = [id]
            unseen.remove(id)
            var index = 0
            while index < queue.count {
                let current = queue[index]
                index += 1
                for next in ordered(neighbours[current, default: []]) where unseen.remove(next) != nil { queue.append(next) }
            }
            components.append(queue.sorted { order[$0]! < order[$1]! })
        }
        var result: [String: CGPoint] = [:]
        let shelfWidth = max(size.width, min(1600, sqrt(CGFloat(ids.count)) * 220))
        var shelfX: CGFloat = 0, shelfY: CGFloat = 0, shelfHeight: CGFloat = 0
        for component in components {
            var remaining = Set(component)
            var degree = Dictionary(uniqueKeysWithValues: component.map { ($0, incoming[$0, default: []].count) })
            var rank = Dictionary(uniqueKeysWithValues: component.map { ($0, 0) })
            while !remaining.isEmpty {
                // Prefer a source; in a cycle, cut the fewest backward edges and keep the order stable.
                let current = remaining.min {
                    if degree[$0]! != degree[$1]! { return degree[$0]! < degree[$1]! }
                    return order[$0]! < order[$1]!
                }!
                remaining.remove(current)
                for next in ordered(outgoing[current, default: []]) where remaining.contains(next) {
                    rank[next] = max(rank[next]!, rank[current]! + 1)
                    degree[next]! -= 1
                }
            }
            let layerCount = (rank.values.max() ?? 0) + 1
            var layers = (0..<layerCount).map { level in component.filter { rank[$0] == level } }
            // Alternate sweeps: place each column in the average order of its connected neighbours.
            for pass in 0..<6 {
                let indices = pass.isMultiple(of: 2) ? Array(0..<layerCount) : Array((0..<layerCount).reversed())
                for layer in indices {
                    let rows = Dictionary(uniqueKeysWithValues: layers.flatMap { $0.enumerated().map { ($1, Double($0)) } })
                    func score(_ id: String) -> Double {
                        let relevant = neighbours[id, default: []].filter {
                            pass.isMultiple(of: 2) ? rank[$0]! < layer : rank[$0]! > layer
                        }
                        let values = relevant.compactMap { rows[$0] }
                        return values.isEmpty ? rows[id]! : values.reduce(0, +) / Double(values.count)
                    }
                    layers[layer].sort {
                        let a = score($0), b = score($1)
                        return a == b ? order[$0]! < order[$1]! : a < b
                    }
                }
            }
            let rowCount = layers.map(\.count).max() ?? 1
            let width = CGFloat(layerCount - 1) * 240 + 200
            let height = CGFloat(rowCount) * 112 + 64
            if shelfX > 0 && shelfX + width > shelfWidth {
                shelfX = 0
                shelfY += shelfHeight + 48
                shelfHeight = 0
            }
            for (column, layer) in layers.enumerated() {
                let top = CGFloat(rowCount - layer.count) * 56
                for (row, id) in layer.enumerated() {
                    result[id] = CGPoint(x: shelfX + 100 + CGFloat(column) * 240,
                                         y: shelfY + 88 + top + CGFloat(row) * 112)
                }
            }
            shelfX += width + 48
            shelfHeight = max(shelfHeight, height)
        }
        let dx = max(0, (size.width - ((result.values.map(\.x).max() ?? 0) + 100)) / 2)
        let dy = max(0, (size.height - ((result.values.map(\.y).max() ?? 0) + 88)) / 2)
        return result.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

}

/// Pointer coordinates are always in the graph, never in the moving card. Preserve the grab offset
/// through every update, and clear it on release so a subsequent drag starts from the current position.
struct MissionGraphInteraction {
    var positions: [String: CGPoint] = [:]
    private var draggedID: String?
    private var offset = CGSize.zero

    mutating func move(_ id: String, start: CGPoint, location: CGPoint, in size: CGSize, scale: CGFloat = 1) {
        guard let position = positions[id] else { return }
        let start = CGPoint(x: start.x / scale, y: start.y / scale)
        let location = CGPoint(x: location.x / scale, y: location.y / scale)
        if draggedID != id {
            draggedID = id
            offset = CGSize(width: position.x - start.x, height: position.y - start.y)
        }
        positions[id] = CGPoint(
            x: min(max(82, location.x + offset.width), max(82, size.width - 82)),
            y: min(max(38, location.y + offset.height), max(38, size.height - 38)))
    }

    mutating func end() { draggedID = nil }
}

/// Fit and user magnification share one bounded scale; layout coordinates stay unchanged by zoom.
struct MissionGraphViewport {
    private(set) var scale: CGFloat = 1

    func renderPosition(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }
    func modelPosition(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / scale, y: point.y / scale) }
    func renderSize(_ size: CGSize) -> CGSize { CGSize(width: size.width * scale, height: size.height * scale) }

    mutating func setScale(_ value: CGFloat) { scale = min(3, max(0.05, value)) }
    mutating func zoom(by factor: CGFloat) { setScale(scale * factor) }
    mutating func fit(canvas: CGSize, inside available: CGSize) {
        setScale(min(1, available.width / max(1, canvas.width), available.height / max(1, canvas.height)))
    }
}

/// A passive probe inside the native scroll view. It never participates in hit testing and only
/// consumes middle-button drags and discrete wheel zoom, leaving trackpad scrolling and pinch alone.
private struct MissionGraphMiddlePan: NSViewRepresentable {
    let zoom: (CGFloat) -> Void
    func makeNSView(context: Context) -> MissionGraphPanView {
        let view = MissionGraphPanView(frame: .zero)
        view.zoom = zoom
        return view
    }
    func updateNSView(_ view: MissionGraphPanView, context: Context) { view.zoom = zoom }
    static func dismantleNSView(_ view: MissionGraphPanView, coordinator: ()) { view.stopMonitoring() }
}

@MainActor final class MissionGraphPanView: NSView {
    var zoom: ((CGFloat) -> Void)?
    private var monitor: Any?
    private var startLocation: CGPoint?
    private var startOrigin = CGPoint.zero
    private weak var cursorWindow: NSWindow?
    var isPanning: Bool { startLocation != nil }

    /// A four-way move cursor, outlined so it remains visible over light and dark material.
    static let panCursor: NSCursor = {
        let image = NSImage(size: CGSize(width: 28, height: 28), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 3, y: 14)); path.line(to: CGPoint(x: 25, y: 14))
            path.move(to: CGPoint(x: 14, y: 3)); path.line(to: CGPoint(x: 14, y: 25))
            for (tip, a, b) in [
                (CGPoint(x: 3, y: 14), CGPoint(x: 7, y: 18), CGPoint(x: 7, y: 10)),
                (CGPoint(x: 25, y: 14), CGPoint(x: 21, y: 18), CGPoint(x: 21, y: 10)),
                (CGPoint(x: 14, y: 3), CGPoint(x: 10, y: 7), CGPoint(x: 18, y: 7)),
                (CGPoint(x: 14, y: 25), CGPoint(x: 10, y: 21), CGPoint(x: 18, y: 21)),
            ] {
                path.move(to: a); path.line(to: tip); path.line(to: b)
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: 14, y: 14))
    }()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopMonitoring() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp, .cursorUpdate, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .scrollWheel {
                let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
                return self.handleWheel(delta: delta, precise: event.hasPreciseScrollingDeltas,
                                        inverted: event.isDirectionInvertedFromDevice,
                                        location: event.locationInWindow, in: event.window) ? nil : event
            }
            return self.handle(event.type, button: event.buttonNumber, location: event.locationInWindow, in: event.window) ? nil : event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(cancelled), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelled),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    /// Locations are in window coordinates so scrolling the document cannot move the gesture's origin.
    /// Continue after leaving the clip bounds; accept a release anywhere to avoid a stranded cursor.
    @discardableResult func handle(_ type: NSEvent.EventType, button: Int, location: CGPoint, in eventWindow: NSWindow?) -> Bool {
        if type == .cursorUpdate, isPanning {
            Self.panCursor.set()
            return true
        }
        guard button == 2 else { return false }
        if type == .otherMouseUp, isPanning {
            cancelPan()
            return true
        }
        guard let window, eventWindow === window, let scroll = enclosingScrollView else { return false }
        let clip = scroll.contentView
        switch type {
        case .otherMouseDown:
            guard !isPanning, clip.bounds.contains(clip.convert(location, from: nil)) else { return false }
            startLocation = location
            startOrigin = clip.bounds.origin
            cursorWindow = window
            window.disableCursorRects()
            Self.panCursor.push()
            return true
        case .otherMouseDragged:
            guard let startLocation else { return false }
            let start = clip.convert(startLocation, from: nil)
            let current = clip.convert(location, from: nil)
            let proposed = CGRect(origin: CGPoint(x: startOrigin.x - (current.x - start.x),
                                                  y: startOrigin.y - (current.y - start.y)), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
            Self.panCursor.set()
            return true
        default:
            return false
        }
    }

    /// Precise scroll events belong to the trackpad. Discrete wheel ticks zoom without scrolling
    /// the clip view; undo the natural-scroll preference so the physical wheel direction is stable.
    @discardableResult func handleWheel(delta: CGFloat, precise: Bool, inverted: Bool,
                                        location: CGPoint, in eventWindow: NSWindow?) -> Bool {
        guard !precise, delta != 0, let zoom, let window, eventWindow === window,
              let clip = enclosingScrollView?.contentView,
              clip.bounds.contains(clip.convert(location, from: nil)) else { return false }
        let direction: CGFloat = inverted ? -1 : 1
        zoom(exp(min(0.5, max(-0.5, delta * direction * 0.12))))
        return true
    }

    @objc private func cancelled(_ notification: Notification) { cancelPan() }

    func cancelPan() {
        guard isPanning else { return }
        startLocation = nil
        NSCursor.pop()
        if let window = cursorWindow {
            window.enableCursorRects()
            if let content = window.contentView { window.invalidateCursorRects(for: content) }
            window.resetCursorRects()
        }
        cursorWindow = nil
    }

    func stopMonitoring() {
        cancelPan()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }
}
