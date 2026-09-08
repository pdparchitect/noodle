import SwiftUI
import NoodleCore

struct AgentConfigurationFields: View {
    @Environment(NoodleStore.self) private var store
    @Binding var selectedHarnessIdentifier: String
    @Binding var selectedModelIdentifier: String
    @Binding var selectedEffort: String
    @State private var choosingHarness = false
    @State private var choosingModel = false

    private var models: [HarnessModel] {
        store.runtime.models(for: selectedHarnessIdentifier)
    }

    private var selectedModel: HarnessModel? {
        models.first { $0.id == selectedModelIdentifier }
    }

    private var selectedProvider: HarnessProvider? {
        HarnessProvider(rawValue: selectedHarnessIdentifier)
    }

    private var selectedInstallation: HarnessInstallation? {
        store.runtime.availableInstallations.first {
            $0.provider.rawValue == selectedHarnessIdentifier
        }
    }

    private var modelName: String {
        if let selectedModel { return selectedModel.displayName }
        if let selectedProvider { return "\(selectedProvider.displayName) default" }
        return "Harness default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Agent Runtime")
                .font(.caption.weight(.semibold))

            VStack(spacing: 0) {
                Button { choosingHarness = true } label: {
                    RuntimeSelectionRow(
                        title: "Harness",
                        value: selectedProvider?.displayName ?? "Choose a harness",
                        icon: AnyView(providerIcon)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $choosingHarness, arrowEdge: .leading) {
                    HarnessChooser(
                        installations: store.runtime.availableInstallations,
                        selection: $selectedHarnessIdentifier
                    )
                }

                Divider().padding(.leading, 44)

                Button { choosingModel = true } label: {
                    RuntimeSelectionRow(
                        title: "Model",
                        value: modelName,
                        icon: AnyView(Image(systemName: "cube.transparent")),
                        isLoading: store.runtime.isLoadingCapabilities
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.runtime.isLoadingCapabilities && models.isEmpty)
                .popover(isPresented: $choosingModel, arrowEdge: .leading) {
                    ModelChooser(
                        providerName: selectedProvider?.displayName ?? "Harness",
                        models: models,
                        selection: $selectedModelIdentifier
                    )
                }

                Divider().padding(.leading, 44)

                EffortControl(model: selectedModel, selection: $selectedEffort)
            }
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.11))
            }

            if let selectedProvider, let error = store.runtime.capabilityErrors[selectedProvider] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: selectedHarnessIdentifier) { _, _ in
            selectedModelIdentifier = ""
            selectedEffort = ""
        }
        .onChange(of: selectedModelIdentifier) { _, newValue in
            guard let model = models.first(where: { $0.id == newValue }) else {
                selectedEffort = ""
                return
            }
            if !model.supportedEfforts.contains(where: { $0.id == selectedEffort }) {
                selectedEffort = model.defaultEffort
            }
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let selectedInstallation {
            HarnessProviderIcon(provider: selectedInstallation.provider)
        } else {
            Image(systemName: "terminal")
        }
    }
}

private struct RuntimeSelectionRow: View {
    let title: String
    let value: String
    let icon: AnyView
    var isLoading = false

    var body: some View {
        HStack(spacing: 11) {
            icon
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .frame(height: 50)
    }
}

private struct HarnessChooser: View {
    let installations: [HarnessInstallation]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose Harness")
                .font(.headline)
                .padding(14)

            Divider()

            List(installations) { installation in
                Button {
                    selection = installation.provider.rawValue
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        HarnessProviderIcon(provider: installation.provider)
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                        Text(installation.provider.displayName)
                        Spacer()
                        if selection == installation.provider.rawValue {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .frame(width: 300, height: max(110, min(320, 62 + CGFloat(installations.count) * 44)))
    }
}

private struct ModelChooser: View {
    let providerName: String
    let models: [HarnessModel]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filteredModels: [HarnessModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.displayName.localizedStandardContains(query) ||
                $0.id.localizedStandardContains(query) ||
                $0.description.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                ModelSearchField(text: $query)
                    .frame(height: 20)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(12)

            Divider()

            List {
                modelButton(
                    id: "",
                    name: "\(providerName) default",
                    description: "Use the harness default model."
                )

                ForEach(filteredModels) { model in
                    modelButton(id: model.id, name: model.displayName, description: model.description)
                }

                if filteredModels.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .listStyle(.inset)

            Divider()

            Text(models.count == 1 ? "1 known model" : "\(models.count) known models")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .frame(height: 34)
        }
        .frame(width: 390, height: 420)
    }

    private func modelButton(id: String, name: String, description: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: id.isEmpty ? "wand.and.stars" : "cube.transparent")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .fontWeight(.medium)
                    if !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 10)
                if selection == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

private struct EffortControl: View {
    let model: HarnessModel?
    @Binding var selection: String

    private var efforts: [HarnessEffort] {
        model?.supportedEfforts ?? []
    }

    private var choices: [String] {
        [""] + efforts.map(\.id)
    }

    private var selectedIndex: Int {
        choices.firstIndex(of: selection) ?? 0
    }

    private var selectionName: String {
        guard !selection.isEmpty else { return "Model default" }
        return efforts.first(where: { $0.id == selection })?.displayName ?? selection.capitalized
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label("Effort", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(selectionName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selection.isEmpty ? Color.secondary : Color.accentColor)
            }

            Group {
                if choices.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(selectedIndex) },
                            set: { selection = choices[Int($0.rounded()).clamped(to: choices.indices)] }
                        ),
                        in: 0...Double(choices.count - 1),
                        step: 1
                    )
                    .controlSize(.small)
                    .accessibilityLabel("Reasoning Effort")
                    .accessibilityValue(selectionName)
                } else {
                    Text("Choose a model to tune its effort")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
