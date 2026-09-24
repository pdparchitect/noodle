import Charts
import NoodleCore
import Observation
import SwiftUI

@MainActor
@Observable
final class UsageHistory {
    private(set) var revision = 0
    /// Set before opening the window to show one bot.
    var agentFilter: UUID?
    @ObservationIgnored private let ledger: UsageLedger?

    init(url: URL) {
        ledger = try? UsageLedger(url: url)
    }

    func record(_ sample: UsageSample) {
        guard (try? ledger?.record(sample)) != nil else { return }
        revision += 1
    }

    func days(from start: Date, to end: Date, agentID: UUID?) -> [UsageDay] {
        (try? ledger?.days(from: start, to: end, agentID: agentID)) ?? []
    }
}

struct UsageMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    let history: UsageHistory

    var body: some View {
        Button("Usage") {
            history.agentFilter = nil
            openWindow(id: UsageView.windowID)
        }
        .appShortcut(.showUsage)
    }
}

struct UsageView: View {
    static let windowID = "usage"

    enum Span: String, CaseIterable, Identifiable {
        case week = "7 Days", month = "30 Days", year = "12 Months"
        var id: Self { self }
    }

    enum Grouping: String, CaseIterable, Identifiable {
        case agent = "Bot", harness = "Harness", model = "Model"
        var id: Self { self }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", cost = "Cost"
        var id: Self { self }
    }

    struct Bar: Identifiable {
        let bucket: Date
        let group: String
        let value: Double
        var id: String { "\(bucket.timeIntervalSince1970)|\(group)" }
    }

    struct Row: Identifiable {
        let group: String
        let tokens: UsageTokens
        let cost: Double?
        var id: String { group }
    }

    @Environment(NoodleStore.self) private var store
    @State private var span = Span.month
    @State private var grouping = Grouping.agent
    @State private var metric = Metric.tokens
    @State private var selectedBucket: Date?

    private static let otherGroup = "Other"
    /// Categorical hues in fixed order, stepped for the dark surface; anything past them folds into Other.
    private static let hues: [Color] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9].map {
        Color(red: Double(($0 >> 16) & 0xff) / 255, green: Double(($0 >> 8) & 0xff) / 255, blue: Double($0 & 0xff) / 255)
    }

    var body: some View {
        let history = store.usage
        let _ = history.revision
        let days = history.days(from: range.lowerBound, to: range.upperBound, agentID: history.agentFilter)
        let rows = rows(days)
        let groups = legendGroups(rows)
        VStack(alignment: .leading, spacing: 16) {
            controls(history)
            if days.isEmpty {
                ContentUnavailableView("No Usage", systemImage: "chart.bar")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tiles(days)
                chart(bars(days, groups: groups), groups: groups)
                    .frame(minHeight: 240)
                ScrollView { breakdown(rows, groups: groups) }
                    .frame(maxHeight: 200)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
    }

    private func controls(_ history: UsageHistory) -> some View {
        @Bindable var history = history
        return HStack(spacing: 12) {
            Picker("Bot", selection: $history.agentFilter) {
                Text("All Bots").tag(UUID?.none)
                ForEach(store.agents) { agent in
                    Text(agent.displayName).tag(Optional(agent.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Group By", selection: $grouping) {
                ForEach(Grouping.allCases) { Text("By \($0.rawValue)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Group By")
            Picker("Measure", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Picker("Period", selection: $span) {
                ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func tiles(_ days: [UsageDay]) -> some View {
        let tokens = days.reduce(UsageTokens()) { $0 + $1.tokens }
        let costs = days.compactMap(\.costUSD)
        let cached = tokens.promptTotal > 0 ? Double(tokens.cacheRead) / Double(tokens.promptTotal) : 0
        let dayCount = max(1, Calendar.current.dateComponents([.day], from: range.lowerBound, to: min(range.upperBound, Date())).day ?? 1)
        return HStack(spacing: 12) {
            tile("Tokens", Self.tokenText(tokens.total))
            tile("Cost", costs.isEmpty ? "—" : Self.costText(costs.reduce(0, +)))
                .help("Only harnesses that report cost are included.")
            tile("Cache Hits", cached.formatted(.percent.precision(.fractionLength(0))))
                .help("Share of input tokens read from the cache.")
            tile("Output", Self.tokenText(tokens.output))
            tile("Daily Average", metric == .cost
                ? Self.costText(costs.reduce(0, +) / Double(dayCount))
                : Self.tokenText(tokens.total / dayCount))
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chart(_ bars: [Bar], groups: [String]) -> some View {
        let unit: Calendar.Component = span == .year ? .month : .day
        let selected = selectedBucket.map { Calendar.current.dateInterval(of: unit, for: $0)?.start ?? $0 }
        return Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Date", bar.bucket, unit: unit), y: .value(metric.rawValue, bar.value))
                    .foregroundStyle(by: .value(grouping.rawValue, bar.group))
                    .opacity(selected == nil || selected == bar.bucket ? 1 : 0.4)
            }
            if let selected {
                RuleMark(x: .value("Date", selected, unit: unit))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(bars.filter { $0.bucket == selected }, date: selected, groups: groups)
                    }
            }
        }
        .chartForegroundStyleScale(domain: groups, range: colors(for: groups))
        .chartXSelection(value: $selectedBucket)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric == .cost ? Self.costText(number) : Self.tokenText(Int(number)))
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
    }

    private func tooltip(_ bars: [Bar], date: Date, groups: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date, format: span == .year ? .dateTime.month(.wide).year() : .dateTime.weekday().day().month())
                .font(.caption.weight(.semibold))
            ForEach(bars.sorted { $0.value > $1.value }) { bar in
                HStack(spacing: 6) {
                    Circle().fill(color(for: bar.group, in: groups)).frame(width: 8, height: 8)
                    Text(bar.group)
                    Spacer(minLength: 12)
                    Text(metric == .cost ? Self.costText(bar.value) : Self.tokenText(Int(bar.value))).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func breakdown(_ rows: [Row], groups: [String]) -> some View {
        let total = rows.reduce(0) { $0 + value(tokens: $1.tokens, cost: $1.cost) }
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text(grouping.rawValue)
                Text("Tokens").gridColumnAlignment(.trailing)
                Text("Input").gridColumnAlignment(.trailing)
                Text("Output").gridColumnAlignment(.trailing)
                Text("Cached").gridColumnAlignment(.trailing)
                Text("Cost").gridColumnAlignment(.trailing)
                Text("Share").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(color(for: row.group, in: groups)).frame(width: 8, height: 8)
                        Text(row.group).lineLimit(1)
                    }
                    Text(Self.tokenText(row.tokens.total))
                    Text(Self.tokenText(row.tokens.input + row.tokens.cacheWrite))
                    Text(Self.tokenText(row.tokens.output))
                    Text(Self.tokenText(row.tokens.cacheRead))
                    Text(row.cost.map(Self.costText) ?? "—")
                    Text(total > 0 ? (value(tokens: row.tokens, cost: row.cost) / total).formatted(.percent.precision(.fractionLength(0))) : "—")
                }
                .monospacedDigit()
            }
        }
    }

    private var range: Range<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch span {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)!..<tomorrow
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)!..<tomorrow
        case .year:
            let month = calendar.dateInterval(of: .month, for: today)!.start
            return calendar.date(byAdding: .month, value: -11, to: month)!..<tomorrow
        }
    }

    private func group(_ day: UsageDay) -> String {
        switch grouping {
        case .agent: day.agentName
        case .harness: HarnessProvider(rawValue: day.harness)?.displayName ?? day.harness
        case .model: day.model.isEmpty ? "Default Model" : day.model
        }
    }

    private func value(tokens: UsageTokens, cost: Double?) -> Double {
        metric == .cost ? cost ?? 0 : Double(tokens.total)
    }

    private func rows(_ days: [UsageDay]) -> [Row] {
        Dictionary(grouping: days, by: group).map { group, days in
            let costs = days.compactMap(\.costUSD)
            return Row(group: group, tokens: days.reduce(UsageTokens()) { $0 + $1.tokens },
                       cost: costs.isEmpty ? nil : costs.reduce(0, +))
        }
        .sorted { value(tokens: $0.tokens, cost: $0.cost) > value(tokens: $1.tokens, cost: $1.cost) }
    }

    /// The largest groups keep their own hue; hues go in name order so a new
    /// period or measure does not repaint a bot just because its rank changed.
    private func legendGroups(_ rows: [Row]) -> [String] {
        let named = rows.prefix(Self.hues.count).map(\.group).sorted()
        return rows.count > Self.hues.count ? named + [Self.otherGroup] : named
    }

    private func colors(for groups: [String]) -> [Color] {
        groups.map { color(for: $0, in: groups) }
    }

    private func color(for group: String, in groups: [String]) -> Color {
        guard group != Self.otherGroup, let index = groups.firstIndex(of: group), index < Self.hues.count else { return .gray }
        return Self.hues[index]
    }

    private func bars(_ days: [UsageDay], groups: [String]) -> [Bar] {
        let unit: Calendar.Component = span == .year ? .month : .day
        var sums: [Date: [String: Double]] = [:]
        for day in days {
            let bucket = Calendar.current.dateInterval(of: unit, for: day.day)?.start ?? day.day
            var name = group(day)
            if !groups.contains(name) { name = Self.otherGroup }
            sums[bucket, default: [:]][name, default: 0] += value(tokens: day.tokens, cost: day.costUSD)
        }
        return sums.flatMap { bucket, values in
            values.map { Bar(bucket: bucket, group: $0.key, value: $0.value) }
        }
        .sorted { ($0.bucket, groups.firstIndex(of: $0.group) ?? 0) < ($1.bucket, groups.firstIndex(of: $1.group) ?? 0) }
    }

    private static func tokenText(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    private static func costText(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 && value > 0 ? 3 : 2)))
    }
}
