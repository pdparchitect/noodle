import SwiftUI
import SuperBotCore

struct AgentApprovalView: View {
    @Environment(SuperBotStore.self) private var store
    let request: AgentApprovalRequest
    @State private var showingDetails = false
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(agentName): \(request.title)", systemImage: "hand.raised.fill")
                .font(.headline)
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: showingDetails ? 240 : 65)
                Button(showingDetails ? "Less Detail" : "Review Full Request") { showingDetails.toggle() }
                    .font(.caption)
            }
            if request.isQuestion {
                ForEach(Array(request.questions.enumerated()), id: \.offset) { _, question in
                    if let id = question["id"] as? String, let text = question["question"] as? String {
                        Text(text).font(.callout)
                        if let options = question["options"] as? [[String: Any]] {
                            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                if let label = option["label"] as? String {
                                    Button { answers[id] = label } label: {
                                        HStack {
                                            Image(systemName: answers[id] == label ? "largecircle.fill.circle" : "circle")
                                            Text(label + ((option["description"] as? String).map { " — \($0)" } ?? ""))
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if question["isSecret"] as? Bool == true {
                            SecureField("Your response", text: answerBinding(id))
                        } else {
                            TextField("Your response", text: answerBinding(id))
                        }
                    }
                }
            }
            if !request.canAllow && !request.isQuestion {
                Text("This request cannot be approved safely in this version. Decline it and ask the bot to use a supported action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Waiting for you · applies to this bot’s current task")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Decline") { store.runtime.resolveApproval(request, allow: false) }
                if request.isQuestion {
                    Button("Send Response") { store.runtime.resolveApproval(request, allow: true, answers: answers) }
                        .disabled(request.questions.contains { (answers[$0["id"] as? String ?? ""] ?? "").isEmpty })
                } else if request.canAllow {
                    Button(request.method == "item/permissions/requestApproval" ? "Allow for This Turn" : "Allow Once") {
                        store.runtime.resolveApproval(request, allow: true)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.5)))
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var agentName: String { store.agents.first { $0.id == request.agentID }?.displayName ?? "Agent" }
    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}
