import NoodleCore
import NoodleRuntime
import SwiftUI

/// Opens the bot's spending budget in a sheet, which saves it on Apply, as Background does.
struct BotBudgetSettingsRow: View {
    @Environment(NoodleStore.self) private var store
    let agent: AgentRecord
    @State private var editing = false

    var body: some View {
        let budget = store.budgets.budgets[agent.id]
        Button { editing = true } label: {
            HStack {
                Label("Spending Budget", systemImage: "gauge.with.dots.needle.67percent")
                Spacer()
                if store.budgets.holds[agent.id] != nil {
                    Text("Reached").foregroundStyle(.orange)
                } else {
                    Text(budget.map { "\($0.limit.tokens.formatted()) per \($0.limit.periodName)" } ?? "None")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) { BotBudgetSheet(agent: agent).noodleSheetSizing() }
    }
}

private struct BotBudgetSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: AgentRecord
    @State private var draft: TokenLimit?
    @State private var loaded = false

    private var saved: TokenLimit? { store.budgets.budgets[agent.id]?.limit }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
                Text("Spending Budget").font(.headline)
                Spacer()
                Button("Apply") {
                    store.setBudget(draft, for: agent)
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(draft == saved)
                .keyboardShortcut(.defaultAction)
            }

            VStack(spacing: 0) { limitRow }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            Text("Once \(agent.displayName) uses this many tokens in the period, it finishes its turn and stops. "
                 + "Messages wait for it until its oldest tokens leave the period or you reset the budget.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let budget = store.budgets.budgets[agent.id] {
                usage(budget)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = saved
        }
    }

    /// Tokens per period, and once there is a limit, the period it counts them over, as a Hub plan sets one per user.
    private var limitRow: some View {
        let set = { (tokens: Int?, length: Int?, unit: TokenLimit.Unit?) in
            draft = (tokens ?? draft?.tokens).map {
                TokenLimit(tokens: $0, length: length ?? draft?.length ?? 1, unit: unit ?? draft?.unit ?? .weeks)
            }
        }
        return HStack(spacing: 8) {
            Text("Tokens")
            Spacer()
            TextField("Tokens", value: Binding(get: { draft?.tokens }, set: { tokens in
                if let tokens { set(tokens, nil, nil) } else { draft = nil }
            }), format: .number, prompt: Text("No limit"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
            if let draft {
                Text("per")
                TextField("Period", value: Binding(get: { draft.length }, set: { set(nil, $0, nil) }), format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Picker("Period", selection: Binding(get: { draft.unit }, set: { set(nil, nil, $0) })) {
                    ForEach(TokenLimit.Unit.allCases, id: \.self) { Text($0.name(count: draft.length)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// What the saved budget counts now, and Reset, which takes effect at once.
    private func usage(_ budget: BotBudget) -> some View {
        // Read with the usage revision, so it follows the bot's turns while the sheet is open.
        let _ = store.usage.revision
        let used = store.budgets.used(by: agent.id) ?? 0
        let until = store.budgets.holds[agent.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Used")
                Spacer()
                Text("\(used.formatted()) of \(budget.limit.tokens.formatted()) tokens")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(min(used, budget.limit.tokens)), total: Double(budget.limit.tokens))
                .tint(until == nil ? .accentColor : .orange)
            if let until {
                Label(BotBudgets.status(until: until), systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let resetAt = budget.resetAt, resetAt > Date().addingTimeInterval(-budget.limit.period) {
                Text("Counting since the reset \(resetAt.formatted(.relative(presentation: .named))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Reset Budget") { store.resetBudget(for: agent) }
                    .disabled(used == 0)
                    .help("Forget the tokens used so far, so \(agent.displayName) may use its whole budget again from now.")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
