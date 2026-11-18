import AppKit
import Charts
import NoodleCore
import NoodleRuntime
import SwiftUI

/// The people on a Hub, to group and filter its usage by. Noodle has none.
public struct UsagePeople: Equatable {
    struct User: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    static let unknown = "Unknown"

    /// By name; a repeated name gets a number.
    let users: [User]
    private let labels: [UUID: String]
    private let botOwners: [UUID: UUID]

    /// `botOwners` gives the owner of each bot that still exists.
    public init(names: [UUID: String] = [:], botOwners: [UUID: UUID] = [:]) {
        var labels: [UUID: String] = [:]
        for (name, ids) in Dictionary(grouping: names.keys, by: { names[$0]! }) {
            for (index, id) in ids.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                labels[id] = index == 0 ? name : "\(name) (\(index + 1))"
            }
        }
        self.labels = labels
        self.botOwners = botOwners
        users = labels.map { User(id: $0.key, name: $0.value) }
            .sorted { $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var isEmpty: Bool { users.isEmpty }

    /// Whose bot it was when it was used. Records from before owners were kept count for the bot's
    /// owner now; a deleted bot's, or one of someone no longer on the Hub, belong to nobody.
    func owner(of day: UsageDay) -> UUID? {
        guard let owner = day.owner ?? botOwners[day.agentID], labels[owner] != nil else { return nil }
        return owner
    }

    func label(of day: UsageDay) -> String {
        owner(of: day).flatMap { labels[$0] } ?? Self.unknown
    }
}

/// Everything the Usage window shows, computed from the ledger's days.
struct UsageReport {
    enum Span: String, CaseIterable, Identifiable {
        case week = "7 Days", month = "30 Days", year = "12 Months"
        var id: Self { self }
        var bucket: Calendar.Component { self == .year ? .month : .day }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case agent = "Bot", user = "User", harness = "Harness", model = "Model"
        var id: Self { self }
    }

    /// Whose usage a Hub's window shows, when not everyone's.
    enum UserFilter: Hashable {
        case user(UUID)
        case unknown
    }

    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", cost = "Cost", disk = "Disk"
        var id: Self { self }
    }

    struct Bar: Identifiable, Equatable {
        let bucket: Date
        let group: String
        let value: Double
        var id: String { "\(bucket.timeIntervalSince1970)|\(group)" }
    }

    struct Row: Identifiable, Equatable {
        let group: String
        let tokens: UsageTokens
        let cost: Double?
        var id: String { group }
    }

    static let otherGroup = "Other"
    /// Groups past this many fold into Other in the chart.
    static let colorCount = 7

    let metric: Metric
    let rows: [Row]
    /// Chart series in legend order: the largest groups by name, then Other.
    let groups: [String]
    let bars: [Bar]
    let tokens: UsageTokens
    let cost: Double?
    let cacheHitRate: Double
    let dailyAverage: Double

    static func range(_ span: Span, now: Date, calendar: Calendar = .current) -> Range<Date> {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch span {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)!..<tomorrow
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)!..<tomorrow
        case .year:
            let month = calendar.dateInterval(of: .month, for: today)!.start
            return calendar.date(byAdding: .month, value: -11, to: month)!..<tomorrow
        }
    }

    init(days: [UsageDay], span: Span, grouping: Grouping, metric: Metric, now: Date,
         user: UserFilter? = nil, people: UsagePeople = UsagePeople(), calendar: Calendar = .current) {
        self.metric = metric
        let days = days.filter { day in
            switch user {
            case nil: true
            case .user(let id): people.owner(of: day) == id
            case .unknown: people.owner(of: day) == nil
            }
        }
        // Bots are told apart by ID; a repeated name gets a number.
        var botLabels: [UUID: String] = [:]
        for (name, ids) in Dictionary(grouping: Set(days.map(\.agentID)), by: { id in days.first { $0.agentID == id }!.agentName }) {
            for (index, id) in ids.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                botLabels[id] = index == 0 ? name : "\(name) (\(index + 1))"
            }
        }
        func group(_ day: UsageDay) -> String {
            switch grouping {
            case .agent: botLabels[day.agentID] ?? day.agentName
            case .user: people.label(of: day)
            case .harness: HarnessProvider(rawValue: day.harness)?.displayName ?? day.harness
            case .model: day.model.isEmpty ? "Default Model" : day.model
            }
        }
        func value(_ tokens: UsageTokens, _ cost: Double?) -> Double {
            metric == .cost ? cost ?? 0 : Double(tokens.total)
        }
        func sumCost(_ days: [UsageDay]) -> Double? {
            let costs = days.compactMap(\.costUSD)
            return costs.isEmpty ? nil : costs.reduce(0, +)
        }
        rows = Dictionary(grouping: days, by: group).map { group, days in
            Row(group: group, tokens: days.reduce(UsageTokens()) { $0 + $1.tokens }, cost: sumCost(days))
        }
        .sorted { (value($0.tokens, $0.cost), $1.group) > (value($1.tokens, $1.cost), $0.group) }
        // Hues go in name order so a new period or measure does not repaint a
        // group just because its rank changed.
        let named = rows.prefix(Self.colorCount).map(\.group).sorted()
        groups = rows.count > Self.colorCount ? named + [Self.otherGroup] : named
        var sums: [Date: [String: Double]] = [:]
        for day in days {
            let bucket = calendar.dateInterval(of: span.bucket, for: day.day)?.start ?? day.day
            let name = named.contains(group(day)) ? group(day) : Self.otherGroup
            sums[bucket, default: [:]][name, default: 0] += value(day.tokens, day.costUSD)
        }
        let order = groups
        bars = sums.flatMap { bucket, values in values.map { Bar(bucket: bucket, group: $0.key, value: $0.value) } }
            .sorted { ($0.bucket, order.firstIndex(of: $0.group) ?? 0) < ($1.bucket, order.firstIndex(of: $1.group) ?? 0) }
        tokens = days.reduce(UsageTokens()) { $0 + $1.tokens }
        cost = sumCost(days)
        cacheHitRate = tokens.promptTotal > 0 ? Double(tokens.cacheRead) / Double(tokens.promptTotal) : 0
        let range = Self.range(span, now: now, calendar: calendar)
        let dayCount = max(1, calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 1)
        dailyAverage = value(tokens, cost) / Double(dayCount)
    }

    func share(of row: Row) -> Double? {
        let total = rows.reduce(0) { $0 + value(of: $1) }
        return total > 0 ? value(of: row) / total : nil
    }

    private func value(of row: Row) -> Double {
        metric == .cost ? row.cost ?? 0 : Double(row.tokens.total)
    }
}

/// A disk measurement as slices of one pie, largest first.
struct StorageReport {
    enum Grouping: String, CaseIterable, Identifiable {
        case kind = "Kind", bot = "Bot"
        var id: Self { self }
    }

    struct Row: Identifiable, Equatable {
        let group: String
        let bytes: Int64
        var id: String { group }
    }

    static let removedBots = "Removed Bots"

    let rows: [Row]
    /// Pie slices in legend order: the largest groups by name, then Other.
    let groups: [String]
    let slices: [Row]
    let total: Int64

    /// `bots` names the bots that still exist; folders of any other bot count together.
    init(snapshot: StorageSnapshot, grouping: Grouping, bots: [UUID: String]) {
        var sums: [String: Int64] = [:]
        switch grouping {
        case .kind:
            for (kind, bytes) in snapshot.kinds { sums[kind.rawValue, default: 0] += bytes }
        case .bot:
            var labels: [UUID: String] = [:]
            for (name, ids) in Dictionary(grouping: bots.keys, by: { bots[$0]! }) {
                for (index, id) in ids.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                    labels[id] = index == 0 ? name : "\(name) (\(index + 1))"
                }
            }
            for (id, bytes) in snapshot.bots { sums[labels[id] ?? Self.removedBots, default: 0] += bytes }
        }
        rows = sums.filter { $0.value > 0 }.map { Row(group: $0.key, bytes: $0.value) }
            .sorted { ($0.bytes, $1.group) > ($1.bytes, $0.group) }
        let named = rows.prefix(UsageReport.colorCount).map(\.group).sorted()
        groups = rows.count > UsageReport.colorCount ? named + [UsageReport.otherGroup] : named
        let rest = rows.dropFirst(UsageReport.colorCount).reduce(0) { $0 + $1.bytes }
        let rows = rows
        slices = groups.map { group in
            group == UsageReport.otherGroup ? Row(group: group, bytes: rest) : rows.first { $0.group == group }!
        }
        total = rows.reduce(0) { $0 + $1.bytes }
    }

    func share(of row: Row) -> Double? {
        total > 0 ? Double(row.bytes) / Double(total) : nil
    }
}

/// Token use and cost per bot, harness and model, for Noodle and Noodle Hub, and per user on a Hub.
public struct UsageView: View {
    public static let windowID = "usage"

    let history: UsageHistory
    let agents: [AgentRecord]
    let people: UsagePeople
    let storage: StorageUsage?
    @State private var span = UsageReport.Span.month
    @State private var grouping = UsageReport.Grouping.agent
    @State private var user: UsageReport.UserFilter?
    @State private var metric = UsageReport.Metric.tokens
    @State private var storageGrouping = StorageReport.Grouping.kind
    @State private var selectedBucket: Date?
    /// Read only while the window is on screen: SwiftUI keeps a closed window alive to reopen it.
    @State private var days: [UsageDay]?
    @State private var visible = false

    /// Categorical hues in fixed order, stepped for the dark surface; anything past them folds into Other.
    private static let hues: [Color] = ([0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9] as [Int]).map(color)

    /// Spelled out in steps: as one expression, slower compilers give up type-checking it.
    private static func color(_ hex: Int) -> Color {
        let red = Double((hex >> 16) & 0xff) / 255
        let green = Double((hex >> 8) & 0xff) / 255
        let blue = Double(hex & 0xff) / 255
        return Color(red: red, green: green, blue: blue)
    }

    /// `people` adds grouping and filtering by user, on a Hub; `storage` adds the Disk measure.
    public init(history: UsageHistory, agents: [AgentRecord], people: UsagePeople = UsagePeople(), storage: StorageUsage? = nil) {
        self.history = history
        self.agents = agents
        self.people = people
        self.storage = storage
    }

    public var body: some View {
        Group {
            if metric == .disk, let storage {
                disk(storage)
            } else {
                ledger()
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .background(WindowVisibilityObserver { visible = $0 })
        // Each time the Disk measure comes on screen, measure again behind the last result.
        .task(id: visible && metric == .disk) {
            if visible, metric == .disk { storage?.refresh() }
        }
        .toolbar { toolbar() }
    }

    @ViewBuilder
    private func ledger() -> some View {
        let now = Date()
        let range = UsageReport.range(span, now: now)
        let report = UsageReport(days: days ?? [], span: span, grouping: people.isEmpty && grouping == .user ? .agent : grouping,
                                 metric: metric, now: now, user: people.isEmpty ? nil : user, people: people)
        Group {
            if days == nil {
                Color.clear
            } else if report.rows.isEmpty {
                ContentUnavailableView("No Usage", systemImage: "chart.bar.xaxis",
                                       description: Text("No tokens were used in this period."))
            } else {
                VStack(spacing: 0) {
                    summary(report)
                        .padding([.horizontal, .top], 20)
                    chart(report)
                        .frame(minHeight: 200)
                        .padding(20)
                    Divider()
                    breakdown(report)
                        .frame(minHeight: 140)
                }
            }
        }
        .task(id: LedgerQuery(revision: history.revision, span: span, agentID: history.agentFilter, visible: visible)) {
            guard visible else { return }
            let range = UsageReport.range(span, now: Date())
            let loaded = await history.loadDays(from: range.lowerBound, to: range.upperBound, agentID: history.agentFilter)
            // A newer period or record started another read; this one's answer is already out of date.
            guard !Task.isCancelled else { return }
            days = loaded
        }
        .navigationSubtitle(rangeText(range))
    }

    @ViewBuilder
    private func disk(_ storage: StorageUsage) -> some View {
        let bots = Dictionary(agents.map { ($0.id, $0.displayName) }) { first, _ in first }
        Group {
            if let snapshot = storage.snapshot {
                let report = StorageReport(snapshot: snapshot, grouping: storageGrouping, bots: bots)
                VStack(spacing: 0) {
                    diskSummary(snapshot)
                        .padding([.horizontal, .top], 20)
                    pie(report)
                        .frame(minHeight: 200)
                        .padding(20)
                    Divider()
                    diskBreakdown(report)
                        .frame(minHeight: 140)
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSubtitle(storage.isMeasuring ? "Measuring" : storage.snapshot.map { "Measured \($0.date.formatted(date: .omitted, time: .shortened))" } ?? "")
    }

    // The same items for every measure: adding and removing them on each switch to or from Disk held the
    // window for a fifth of a second, and the rest came in late. Those that do not apply to Disk are disabled.
    @ToolbarContentBuilder
    private func toolbar() -> some ToolbarContent {
        let filter = Binding(get: { history.agentFilter }, set: { history.agentFilter = $0 })
        let ledger = metric != .disk
        ToolbarItem(placement: .principal) {
            Picker("Period", selection: $span) {
                ForEach(UsageReport.Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Period")
            .disabled(!ledger)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Bot", selection: filter) {
                Text("All Bots").tag(UUID?.none)
                Divider()
                ForEach(agents) { agent in
                    Label {
                        Text(agent.displayName)
                    } icon: {
                        if let image = BotAvatar.menuImage(for: agent) { Image(nsImage: image) }
                    }
                    .tag(Optional(agent.id))
                }
            }
            .pickerStyle(.menu)
            // Toolbars show only a label's icon unless told otherwise.
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .help("Bot")
            .disabled(!ledger)
        }
        if !people.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Picker("User", selection: $user) {
                    Text("All Users").tag(UsageReport.UserFilter?.none)
                    Divider()
                    ForEach(people.users) { Text($0.name).tag(Optional(UsageReport.UserFilter.user($0.id))) }
                    Text(UsagePeople.unknown).tag(Optional(UsageReport.UserFilter.unknown))
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 6)
                .help("User")
                .disabled(!ledger)
            }
        }
        ToolbarSpacer(.fixed)
        // One picker whose choices follow the measure: a picker of its own for Disk would be a new control.
        ToolbarItem(placement: .primaryAction) {
            Picker("Group By", selection: Binding(
                get: { ledger ? grouping.rawValue : storageGrouping.rawValue },
                set: { value in
                    if ledger { grouping = UsageReport.Grouping(rawValue: value) ?? grouping }
                    else { storageGrouping = StorageReport.Grouping(rawValue: value) ?? storageGrouping }
                })) {
                ForEach(ledger ? UsageReport.Grouping.allCases.filter { $0 != .user || !people.isEmpty }.map(\.rawValue)
                               : StorageReport.Grouping.allCases.map(\.rawValue), id: \.self) { Text("By \($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 6)
            .help("Group By")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Picker("Measure", selection: $metric) {
                ForEach(UsageReport.Metric.allCases.filter { $0 != .disk || storage != nil }) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Measure")
        }
    }

    /// The period's first and last day, or first and last month.
    private func rangeText(_ range: Range<Date>) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: range.upperBound) ?? range.upperBound
        let style: Date.IntervalFormatStyle = span == .year
            ? .interval.month(.abbreviated).year()
            : .interval.day().month(.abbreviated).year()
        return (range.lowerBound..<last).formatted(style)
    }

    private func summary(_ report: UsageReport) -> some View {
        HStack(spacing: 0) {
            stat("Tokens", Self.tokenText(report.tokens.total))
            Divider().frame(height: 36)
            stat("Cost", report.cost.map(Self.costText) ?? "—")
                .help("Only harnesses that report cost are included.")
            Divider().frame(height: 36)
            stat("Cache Hits", report.cacheHitRate.formatted(.percent.precision(.fractionLength(0))))
                .help("Share of input tokens read from the cache.")
            Divider().frame(height: 36)
            stat("Input", Self.tokenText(report.tokens.input + report.tokens.cacheWrite))
                .help("Input tokens not read from the cache.")
            Divider().frame(height: 36)
            stat("Output", Self.tokenText(report.tokens.output))
            Divider().frame(height: 36)
            stat("Daily Average", text(report.dailyAverage))
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func chart(_ report: UsageReport) -> some View {
        let unit = span.bucket
        let selected = selectedBucket.map { Calendar.current.dateInterval(of: unit, for: $0)?.start ?? $0 }
        return Chart {
            ForEach(report.bars) { bar in
                BarMark(x: .value("Date", bar.bucket, unit: unit), y: .value(metric.rawValue, bar.value))
                    .foregroundStyle(by: .value(grouping.rawValue, bar.group))
                    .opacity(selected == nil || selected == bar.bucket ? 1 : 0.4)
            }
            if let selected {
                RuleMark(x: .value("Date", selected, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(report.bars.filter { $0.bucket == selected }, date: selected, groups: report.groups)
                    }
            }
        }
        .chartForegroundStyleScale(domain: report.groups, range: report.groups.map { color(for: $0, in: report.groups) })
        .chartXSelection(value: $selectedBucket)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(text(number)) }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
    }

    private func tooltip(_ bars: [UsageReport.Bar], date: Date, groups: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date, format: span == .year ? .dateTime.month(.wide).year() : .dateTime.weekday().day().month())
                .font(.caption.weight(.semibold))
            ForEach(bars.sorted { $0.value > $1.value }) { bar in
                HStack(spacing: 6) {
                    Circle().fill(color(for: bar.group, in: groups)).frame(width: 8, height: 8)
                    Text(bar.group)
                    Spacer(minLength: 12)
                    Text(text(bar.value)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func breakdown(_ report: UsageReport) -> some View {
        Table(report.rows) {
            TableColumn(grouping.rawValue) { row in
                HStack(spacing: 6) {
                    Circle().fill(color(for: row.group, in: report.groups)).frame(width: 8, height: 8)
                    Text(row.group).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Tokens") { row in Text(Self.tokenText(row.tokens.total)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Input") { row in Text(Self.tokenText(row.tokens.input + row.tokens.cacheWrite)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Output") { row in Text(Self.tokenText(row.tokens.output)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Cached") { row in Text(Self.tokenText(row.tokens.cacheRead)) }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Cost") { row in Text(row.cost.map(Self.costText) ?? "—") }
                .width(min: 64, ideal: 88)
                .alignment(.numeric)
            TableColumn("Share") { row in
                Text(report.share(of: row)?.formatted(.percent.precision(.fractionLength(0))) ?? "—")
            }
            .width(min: 64, ideal: 88)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .monospacedDigit()
    }

    private func diskSummary(_ snapshot: StorageSnapshot) -> some View {
        HStack(spacing: 0) {
            stat("Total", Self.byteText(snapshot.total))
            ForEach([StorageSnapshot.Kind.bots, .conversations, .harnesses, .caches], id: \.self) { kind in
                Divider().frame(height: 36)
                stat(kind.rawValue, Self.byteText(snapshot.kinds[kind] ?? 0))
            }
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pie(_ report: StorageReport) -> some View {
        Chart(report.slices) { slice in
            SectorMark(angle: .value("Size", slice.bytes), angularInset: 1)
                .foregroundStyle(by: .value(storageGrouping.rawValue, slice.group))
                .cornerRadius(3)
        }
        .chartForegroundStyleScale(domain: report.groups, range: report.groups.map { color(for: $0, in: report.groups) })
        .chartLegend(position: .trailing, alignment: .center)
    }

    private func diskBreakdown(_ report: StorageReport) -> some View {
        Table(report.rows) {
            TableColumn(storageGrouping.rawValue) { row in
                HStack(spacing: 6) {
                    Circle().fill(color(for: row.group, in: report.groups)).frame(width: 8, height: 8)
                    Text(row.group).lineLimit(1)
                }
            }
            .width(min: 140, ideal: 260)
            TableColumn("Size") { row in Text(Self.byteText(row.bytes)) }
                .width(min: 64, ideal: 100)
                .alignment(.numeric)
            TableColumn("Share") { row in
                Text(report.share(of: row)?.formatted(.percent.precision(.fractionLength(0))) ?? "—")
            }
            .width(min: 64, ideal: 88)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .monospacedDigit()
    }

    private func color(for group: String, in groups: [String]) -> Color {
        guard group != UsageReport.otherGroup, let index = groups.firstIndex(of: group), index < Self.hues.count else { return .gray }
        return Self.hues[index]
    }

    private func text(_ value: Double) -> String {
        metric == .cost ? Self.costText(value) : Self.tokenText(Int(value))
    }

    private static func tokenText(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    private static func byteText(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    private static func costText(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 && value > 0 ? 3 : 2)))
    }
}

private struct LedgerQuery: Equatable {
    let revision: Int
    let span: UsageReport.Span
    let agentID: UUID?
    let visible: Bool
}

/// Reports whether the hosting window is on screen; closing a window only orders it out.
private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.isVisible, options: [.initial, .new]) { [weak self] window, _ in
                // KVO can fire inside SwiftUI layout; defer the state change.
                let visible = window.isVisible
                DispatchQueue.main.async { self?.onChange?(visible) }
            }
            if window == nil { DispatchQueue.main.async { [weak self] in self?.onChange?(false) } }
        }
    }
}
