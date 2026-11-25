import AppKit
import NoodleCore
import PionCore
import SwiftUI

/// The case record beside an Investigation: its findings, evidence and entities; or the
/// append-only audit log.
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
                if investigation.isAssessment { ChecksSection(model: model, investigation: investigation) }
                if let note = investigation.closingNote {
                    VStack(alignment: .leading, spacing: 6) {
                        Heading(title: "Closing Note")
                        Text(note).font(.callout)
                    }
                }
                if !record.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Heading(title: "Findings", count: record.findings.count)
                        ForEach(record.findings) { finding in FindingRow(model: model, finding: finding) }
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
                            EntityRow(entity: entity)
                        }
                    }
                }
                if record.entities.isEmpty && record.evidence.isEmpty && record.findings.isEmpty && !investigation.isAssessment {
                    Text("No records yet.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }
}

/// An Assessment's checks as the latest run left them, the only results that stand now, each marked new or fixed
/// against the run before.
private struct ChecksSection: View {
    let model: PionModel
    let investigation: Investigation

    var body: some View {
        let runs = model.assessmentRuns(investigation.id)
        VStack(alignment: .leading, spacing: 6) {
            Heading(title: "Checks", count: runs.last?.results.count)
            if let latest = runs.last {
                let before = runs.dropLast().last.map { Dictionary($0.results.map { ($0.checkID, $0.status) }, uniquingKeysWith: { first, _ in first }) }
                // A problem every check that couldn't run shares is said here once, not on each.
                let shared = latest.sharedProblem?.reason
                let notes = [latest.sharedProblemLine, latest.policyGaps.map { "Policy incomplete: \($0)." }].compactMap { $0 }
                Text((["\(latest.tally) Last run \(latest.date.pionShort)\(latest.connection.map { " on \($0)" } ?? "")."] + notes)
                    .joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(latest.results, id: \.checkID) { result in
                    CheckRow(result: result, previous: before.map { $0[result.checkID] }, saysReason: result.reason != shared)
                }
            } else {
                Text(model.isRunningChecks(investigation.id) ? "Running checks…" : "No checks run yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct CheckRow: View {
    let result: CheckResult
    /// The check's status in the run before, nil when it had none; nil altogether on the first run.
    let previous: CheckStatus??
    /// False when the section already said why it couldn't run, as the reason many shared.
    var saysReason = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let change { Tag(text: change.text, color: change.color) }
                    Tag(text: result.severity.title, color: result.status == .fail ? result.severity.color : .secondary)
                }
                if result.status == .couldNotRun, saysReason, let reason = result.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title): \(result.status.title)")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyText("\(result.title): \(result.status.title). \(detail)") }
        }
    }

    private var detail: String {
        var lines = [result.summary ?? result.reason ?? result.status.title]
        if result.offenderCount > 0 {
            let shown = result.offenders.prefix(10)
            lines.append(shown.joined(separator: ", ") + (result.offenderCount > shown.count ? ", and \(result.offenderCount - shown.count) more" : ""))
        }
        let cited = [result.evidenceID, result.findingID].compactMap { $0 }
        if !cited.isEmpty { lines.append(cited.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private var symbol: String {
        switch result.status {
        case .pass: "checkmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        case .couldNotRun: "questionmark.circle"
        }
    }

    private var color: Color {
        switch result.status {
        // Monochrome, as Pion is: a failure stands out by its weight, and in red only when critical.
        case .pass, .couldNotRun: .secondary
        case .fail: result.severity.color
        }
    }

    /// New where it fails now but didn't before; Fixed where it passes now but failed before.
    private var change: (text: String, color: Color)? {
        guard case .some(let before) = previous else { return nil }
        if result.status == .fail, before != .fail { return ("New", .primary) }
        if result.status == .pass, before == .fail { return ("Fixed", .secondary) }
        return nil
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
        .contentShape(.rect(cornerRadius: 8))
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                copyText("\(finding.id) (\(finding.confidence.rawValue) confidence): \(finding.claim)\nEvidence: \(finding.evidence.joined(separator: ", "))")
            }
            if let agent = model.agent(of: finding.recordedBy) {
                Divider()
                Button("Show Activity", systemImage: "list.bullet.rectangle") { model.showActivity(for: agent) }
            }
        }
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
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                copyText("\(evidence.id) from \(evidence.source): \(evidence.result)\nMethod: \(evidence.method)")
            }
            Button("Copy Method", systemImage: "terminal") { copyText(evidence.method) }
            Divider()
            Button(expanded ? "Collapse" : "Expand", systemImage: expanded ? "chevron.up" : "chevron.down") {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }
            if let agent = model.agent(of: evidence.recordedBy) {
                Divider()
                Button("Show Activity", systemImage: "list.bullet.rectangle") { model.showActivity(for: agent) }
            }
        }
    }
}

private struct EntityRow: View {
    let entity: CaseRecord.Entity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entity.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entity.name).font(.callout.monospaced()).textSelection(.enabled)
                if let detail = entity.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyText(entity.name) }
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
                            AuditRow(model: model, investigationID: investigation.id, entry: entry, last: index == items.count - 1)
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
    let model: PionModel
    let investigationID: UUID
    let entry: AuditEntry
    let last: Bool

    var body: some View {
        let actor = model.name(of: entry.actor)
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
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                copyText("\(entry.at.formatted(date: .abbreviated, time: .shortened)) \(Self.title(entry.event)) by \(actor): \(entry.detail)")
            }
            if let agent = model.agent(of: entry.actor) {
                Divider()
                Button("Show Activity", systemImage: "list.bullet.rectangle") { model.showActivity(for: agent) }
            }
            Divider()
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.store.auditURL(investigationID)])
            }
        }
    }

    static func title(_ event: String) -> String {
        switch event {
        case "status": "Status Changed"
        case "finding": "Finding"
        case "evidence": "Evidence"
        case "entity": "Entity"
        case "severity": "Severity Set"
        case "staff": "Team Changed"
        case "opened": "Opened"
        default: event.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func symbol(_ event: String) -> String {
        switch event {
        case "status": "arrow.triangle.swap"
        case "finding": "exclamationmark"
        case "evidence": "doc.text.magnifyingglass"
        case "entity": "cube"
        case "severity": "exclamationmark.triangle"
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

extension PionModel {
    /// The agent behind a case entry, while it is still on the roster.
    func agent(of actor: CaseActor) -> AgentRecord? {
        if case .agent(let id) = actor { agent(id) } else { nil }
    }
}
