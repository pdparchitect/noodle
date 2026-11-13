import NoodleCore
import PionCore
import SwiftUI

/// The case record beside an Investigation: what waits for the champion first, then the objective
/// and scope, findings, actions, evidence and entities; or the append-only audit log.
struct CaseInspector: View {
    let model: PionModel
    @Bindable var window: WindowState
    let investigation: Investigation

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $window.inspectorTab) {
                ForEach(WindowState.InspectorTab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch window.inspectorTab {
            case .caseRecord: CaseRecordView(model: model, investigation: investigation)
            case .audit: AuditLogView(model: model, investigation: investigation)
            }
        }
    }
}

private struct Heading: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if let count { Text("\(count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
            Spacer()
        }
    }
}

struct CaseRecordView: View {
    let model: PionModel
    let investigation: Investigation

    var body: some View {
        let record = model.caseRecord(investigation.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !record.pendingActions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Heading(title: "Needs Approval", count: record.pendingActions.count)
                        ForEach(record.pendingActions) { action in
                            ApprovalCard(model: model, investigation: investigation, action: action, record: record)
                        }
                    }
                }
                ScopeSection(model: model, investigation: investigation)
                if !record.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Heading(title: "Findings", count: record.findings.count)
                        ForEach(record.findings) { finding in FindingRow(model: model, finding: finding) }
                    }
                }
                let decided = record.actions.filter { $0.state != .pending }
                if !decided.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Heading(title: "Actions", count: decided.count)
                        ForEach(decided.reversed()) { action in ActionRow(model: model, investigation: investigation, action: action) }
                    }
                }
                if !record.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Heading(title: "Evidence", count: record.evidence.count)
                        ForEach(record.evidence) { item in EvidenceRow(model: model, evidence: item) }
                    }
                }
                if !record.entities.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Heading(title: "Entities", count: record.entities.count)
                        ForEach(record.entities) { entity in
                            EntityRow(entity: entity, inScope: investigation.covers(entity.name), protected: model.policy.isProtected(entity.name))
                        }
                    }
                }
                if record.entities.isEmpty && record.evidence.isEmpty && record.findings.isEmpty && record.actions.isEmpty {
                    Text("No records yet.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }
}

/// An action waiting for the champion, with what is needed to decide it.
struct ApprovalCard: View {
    let model: PionModel
    let investigation: Investigation
    let action: CaseRecord.ProposedAction
    let record: CaseRecord
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(action.operation).font(.callout.monospaced().weight(.semibold))
                Spacer()
                Text(action.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                field("Targets", action.targets.joined(separator: ", "), mono: true)
                field("Why", action.rationale)
                field("Effect", action.expectedEffect)
                field("Undo", action.undo)
                if !action.evidence.isEmpty {
                    field("Evidence", action.evidence.map { id in record.evidence.first { $0.id == id }.map { "\(id) \($0.source)" } ?? id }
                        .joined(separator: ", "))
                }
                field("From", model.name(of: action.proposedBy))
            }
            .font(.callout)
            TextField("Note for the team", text: $note)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            HStack {
                Spacer()
                Button("Deny") { model.decide(action, in: investigation, approve: false, note: note) }
                Button("Approve") { model.decide(action, in: investigation, approve: true, note: note) }
                    .buttonStyle(ProminentButtonStyle())
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.35)))
    }

    @ViewBuilder private func field(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ScopeSection: View {
    let model: PionModel
    let investigation: Investigation
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Heading(title: "Scope", count: investigation.scope.count)
                if !investigation.isClosed {
                    Button(editing ? "Done" : "Edit") {
                        if editing { model.setScope(text, of: investigation) } else { text = investigation.scope.joined(separator: "\n") }
                        editing.toggle()
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            if editing {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    .help("One entry per line. *.example.com covers every name under it.")
            } else if investigation.scope.isEmpty {
                Text("Nothing in scope: every action is refused.").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(investigation.scope, id: \.self) { entry in
                        Text(entry).font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 4))
                    }
                }
            }
            if let note = investigation.closingNote {
                Heading(title: "Closing Note")
                Text(note).font(.callout)
            }
        }
    }
}

private struct FindingRow: View {
    let model: PionModel
    let finding: CaseRecord.Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(finding.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Tag(text: finding.confidence.title + " confidence", color: .secondary)
                Spacer()
                Text(model.name(of: finding.recordedBy)).font(.caption).foregroundStyle(.secondary)
            }
            Text(finding.claim).font(.callout).textSelection(.enabled)
            Text("Evidence: " + finding.evidence.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
    }
}

private struct ActionRow: View {
    let model: PionModel
    let investigation: Investigation
    let action: CaseRecord.ProposedAction

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(action.operation).font(.callout.monospaced())
                Spacer()
                Tag(text: action.state.title, color: action.state.color)
            }
            Text(action.targets.joined(separator: ", ")).font(.caption.monospaced())
            if let note = action.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("\(action.id) · \(model.name(of: action.proposedBy)) · \(action.mode.title)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if action.state == .approved, !investigation.isClosed {
                    Button("Mark Done") { model.markDone(action, in: investigation) }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
    }
}

private struct EvidenceRow: View {
    let model: PionModel
    let evidence: CaseRecord.Evidence
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                Text(evidence.method).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 4))
                Text("Collected \(evidence.collectedAt.pionShort) by \(model.name(of: evidence.recordedBy))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            // The whole label opens it, not only the chevron.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(evidence.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(evidence.source).font(.callout.weight(.medium))
                }
                Text(evidence.result).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
        }
    }
}

private struct EntityRow: View {
    let entity: CaseRecord.Entity
    let inScope: Bool
    let protected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entity.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.name).font(.callout.monospaced()).textSelection(.enabled)
                if let detail = entity.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
            if protected { Tag(text: "Protected", color: .secondary, symbol: "lock.fill") } else if inScope { Tag(text: "In Scope", color: .secondary) }
        }
    }
}

/// The append-only log as a timeline, newest first and grouped by day: the time, a marker for the kind
/// of event, what happened, who did it, and the detail beneath.
struct AuditLogView: View {
    let model: PionModel
    let investigation: Investigation

    var body: some View {
        // Newest first; entries made at the same moment keep the order they were logged in.
        let entries = model.audit(investigation.id).enumerated().sorted { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }.map(\.element)
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(days, id: \.key) { day, items in
                    Section {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, entry in
                            AuditRow(entry: entry, actor: model.name(of: entry.actor), last: index == items.count - 1)
                        }
                    } header: {
                        Text(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            // Frosted and fading out at its foot, so entries pass under it without a hard band.
                            .background {
                                Rectangle().fill(.ultraThinMaterial)
                                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                                         startPoint: .top, endPoint: .bottom))
                            }
                    }
                }
            }
            .padding(.bottom, 14)
        }
        .overlay { if entries.isEmpty { Text("Nothing logged yet.").font(.callout).foregroundStyle(.secondary) } }
        .help("Append-only: every change to this Investigation, with who made it.")
    }
}

private struct AuditRow: View {
    let entry: AuditEntry
    let actor: String
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.at.pionTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.top, 3)
            // The rail: a marker per entry, joined to the one below.
            ZStack(alignment: .top) {
                if !last {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).padding(.top, 20)
                }
                Image(systemName: Self.symbol(entry.event))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .frame(width: 20)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.title(entry.event)).font(.callout.weight(.semibold))
                    Spacer(minLength: 6)
                    Text(actor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(entry.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.top, 1)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    static func title(_ event: String) -> String {
        switch event {
        case "status": "Status Changed"
        case "done": "Action Done"
        case "approved": "Action Approved"
        case "denied": "Action Denied"
        case "proposed": "Action Proposed"
        case "finding": "Finding"
        case "evidence": "Evidence"
        case "entity": "Entity"
        case "scope": "Scope Changed"
        case "staff": "Team Changed"
        case "opened": "Opened"
        default: event.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func symbol(_ event: String) -> String {
        switch event {
        case "status": "arrow.triangle.swap"
        case "done": "checkmark"
        case "approved": "checkmark.seal.fill"
        case "denied": "xmark"
        case "proposed": "hand.raised.fill"
        case "finding": "exclamationmark"
        case "evidence": "doc.text.magnifyingglass"
        case "entity": "cube"
        case "scope": "scope"
        case "staff": "person.2.fill"
        case "opened": "flag.fill"
        default: "circle.fill"
        }
    }
}

/// Lays chips out in lines, wrapping as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
