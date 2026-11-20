import RookCore
import SwiftUI

/// The attack graph of a Mission, shown as a floating panel centred over the window: the entities its agents recorded
/// as nodes, and the links between them as directed, labelled edges. Opened from the toolbar and closed on leaving the
/// Mission or clicking away, so it always floats in front rather than taking the conversation's place.
struct MissionGraphView: View {
    let model: RookModel
    let mission: Mission
    let close: () -> Void

    @State private var positions: [String: CGPoint] = [:]

    var body: some View {
        let record = model.caseRecord(mission.id)
        ZStack {
            // Dims the window behind the panel and dismisses it when clicked.
            Rectangle().fill(.black.opacity(0.3)).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text("\(mission.reference) — Attack graph").lineLimit(1)
                    if !record.entities.isEmpty {
                        Text("\(record.entities.count) nodes · \(record.links.count) links")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { close() } label: { Image(systemName: "xmark.circle.fill").imageScale(.large) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Close the graph")
                }
                .font(.headline)
                .padding(16)
                Divider()
                content(record)
            }
            .frame(maxWidth: 900, maxHeight: 680)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.35), radius: 36, y: 14)
            .padding(48)
        }
    }

    @ViewBuilder private func content(_ record: CaseRecord) -> some View {
        if record.entities.isEmpty {
            ContentUnavailableView("No graph yet", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Agents build it as they link what they find — a credential that unlocks an account, a host they pivot to."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                ZStack {
                    Canvas { context, _ in
                        for link in record.links {
                            guard let a = positions[link.from], let b = positions[link.to] else { continue }
                            Self.drawEdge(context, from: a, to: b)
                        }
                    }
                    // Relation labels, as frosted chips so they read over the lines.
                    ForEach(record.links) { link in
                        if let a = positions[link.from], let b = positions[link.to] {
                            Text(link.relation)
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.regularMaterial))
                                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                        }
                    }
                    ForEach(record.entities) { entity in
                        if let point = positions[entity.id] {
                            node(entity).position(point)
                        }
                    }
                }
                .padding(24)
                .onAppear { positions = Self.layout(record, in: inner(geo.size)) }
                .onChange(of: geo.size) { _, size in positions = Self.layout(record, in: inner(size)) }
                .onChange(of: record.entities.count + record.links.count) { positions = Self.layout(record, in: inner(geo.size)) }
            }
        }
    }

    /// The drawing area inside the content padding.
    private func inner(_ size: CGSize) -> CGSize { CGSize(width: max(1, size.width - 48), height: max(1, size.height - 48)) }

    private func node(_ entity: CaseRecord.Entity) -> some View {
        let color = Self.color(entity.kind)
        return HStack(spacing: 6) {
            Image(systemName: entity.kind.symbol).foregroundStyle(color)
            Text(entity.name).foregroundStyle(.primary).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.65), lineWidth: 1.3))
        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
        .help(entity.detail ?? entity.kind.title)
    }

    /// One directed edge: a rounded line that stops short of each node, with an arrowhead at the target.
    static func drawEdge(_ context: GraphicsContext, from a: CGPoint, to b: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(1, hypot(dx, dy))
        let ux = dx / length, uy = dy / length
        let gap: CGFloat = 26
        guard length > gap * 2 else { return }
        let start = CGPoint(x: a.x + ux * gap, y: a.y + uy * gap)
        let end = CGPoint(x: b.x - ux * gap, y: b.y - uy * gap)
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        let head: CGFloat = 8
        let left = CGPoint(x: end.x - ux * head - uy * head * 0.55, y: end.y - uy * head + ux * head * 0.55)
        let right = CGPoint(x: end.x - ux * head + uy * head * 0.55, y: end.y - uy * head - ux * head * 0.55)
        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: left)
        arrow.addLine(to: right)
        arrow.closeSubpath()
        context.fill(arrow, with: .color(.secondary.opacity(0.6)))
    }

    static func color(_ kind: CaseRecord.Entity.Kind) -> Color {
        switch kind {
        case .host: .primary
        case .service: .teal
        case .account: .orange
        case .credential: .red
        case .artifact: .purple
        case .other: .secondary
        }
    }

    /// A small force-directed layout (Fruchterman–Reingold), seeded by position so it is the same each time, then
    /// scaled to fit the panel.
    static func layout(_ record: CaseRecord, in size: CGSize) -> [String: CGPoint] {
        let ids = record.entities.map(\.id)
        guard !ids.isEmpty, size.width > 1, size.height > 1 else { return [:] }
        let edges = record.links.compactMap { link -> (String, String)? in
            ids.contains(link.from) && ids.contains(link.to) ? (link.from, link.to) : nil
        }
        var point: [String: CGPoint] = [:]
        let radius = min(size.width, size.height) * 0.32
        for (index, id) in ids.enumerated() {
            let angle = Double(index) / Double(ids.count) * 2 * .pi
            point[id] = CGPoint(x: size.width / 2 + cos(angle) * radius, y: size.height / 2 + sin(angle) * radius)
        }
        guard ids.count > 1 else { point[ids[0]] = CGPoint(x: size.width / 2, y: size.height / 2); return point }
        let k = sqrt(size.width * size.height / Double(ids.count)) * 0.72
        for step in 0..<400 {
            var disp: [String: CGVector] = [:]
            for a in ids {
                for b in ids where a != b {
                    let dx = point[a]!.x - point[b]!.x, dy = point[a]!.y - point[b]!.y
                    let distance = max(1, hypot(dx, dy))
                    let force = k * k / distance
                    disp[a, default: .zero].dx += dx / distance * force
                    disp[a, default: .zero].dy += dy / distance * force
                }
            }
            for (u, v) in edges {
                let dx = point[u]!.x - point[v]!.x, dy = point[u]!.y - point[v]!.y
                let distance = max(1, hypot(dx, dy))
                let force = distance * distance / k
                disp[u, default: .zero].dx -= dx / distance * force
                disp[u, default: .zero].dy -= dy / distance * force
                disp[v, default: .zero].dx += dx / distance * force
                disp[v, default: .zero].dy += dy / distance * force
            }
            let temperature = max(2, 22 * (1 - Double(step) / 400))
            for id in ids {
                let move = disp[id] ?? .zero
                let distance = max(1, hypot(move.dx, move.dy))
                point[id]!.x += move.dx / distance * min(distance, temperature)
                point[id]!.y += move.dy / distance * min(distance, temperature)
            }
        }
        let margin: CGFloat = 60
        let xs = point.values.map(\.x), ys = point.values.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let width = max(1, maxX - minX), height = max(1, maxY - minY)
        let scale = min((size.width - 2 * margin) / width, (size.height - 2 * margin) / height, 1.4)
        for id in ids {
            point[id] = CGPoint(x: (point[id]!.x - minX) * scale + (size.width - width * scale) / 2,
                                y: (point[id]!.y - minY) * scale + (size.height - height * scale) / 2)
        }
        return point
    }
}
