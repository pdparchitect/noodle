import SwiftUI
import NoodleCore

struct AgentConfigurationFields: View {
    @Environment(NoodleStore.self) private var store
    @Binding var selectedHarnessIdentifier: String
    @Binding var selectedModelIdentifier: String
    @Binding var selectedEffort: String
    @Binding var selectedProfileID: UUID?
    @State private var choosingHarness = false
    @State private var choosingProfile = false
    @State private var choosingModel = false

    private var profiles: [HarnessProfile] {
        guard let selectedProvider, selectedProvider.supportsProfiles else { return [] }
        return store.harnessProfiles.profiles(for: selectedProvider)
    }

    private var models: [HarnessModel] {
        store.runtime.models(for: selectedHarnessIdentifier)
    }

    private var selectedModel: HarnessModel? {
        if selectedProvider == .apple, selectedModelIdentifier.isEmpty { return models.first(where: \.isDefault) }
        return models.first { $0.id == selectedModelIdentifier }
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
            Text("Harness")
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

                if !profiles.isEmpty {
                    Divider().padding(.leading, 44)

                    Button { choosingProfile = true } label: {
                        RuntimeSelectionRow(
                            title: "Profile",
                            value: store.harnessProfiles.profile(selectedProfileID)?.displayName ?? "System",
                            icon: AnyView(Image(systemName: "person.crop.circle"))
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $choosingProfile, arrowEdge: .leading) {
                        HarnessProfileChooser(profiles: profiles, selection: $selectedProfileID)
                    }
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
                        usesCatalogueDefault: selectedProvider == .apple,
                        models: models,
                        selection: $selectedModelIdentifier
                    )
                }

                if selectedProvider != .apple || selectedModel?.supportedEfforts.isEmpty == false {
                    Divider().padding(.leading, 44)
                    EffortControl(model: selectedModel, selection: $selectedEffort)
                }
            }
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.11))
            }

            HarnessExperimentalWarning(provider: selectedProvider)

            if let selectedProvider, !selectedProvider.supportsRestrictedAccess {
                Text("\(selectedProvider.displayName) always uses unrestricted access and can work beyond this bot's private workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            selectedProfileID = nil
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

struct HarnessChooser: View {
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
                        if installation.provider.isExperimental {
                            Text("Experimental")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
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

struct HarnessProfileChooser: View {
    let profiles: [HarnessProfile]
    @Binding var selection: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose Profile")
                .font(.headline)
                .padding(14)

            Divider()

            List {
                profileButton(id: nil, name: "System")
                ForEach(profiles) { profileButton(id: $0.id, name: $0.displayName) }
            }
            .listStyle(.inset)
        }
        .frame(width: 300, height: max(110, min(320, 62 + CGFloat(profiles.count + 1) * 44)))
    }

    private func profileButton(id: UUID?, name: String) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: id == nil ? "house" : "person.crop.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                Text(name)
                Spacer()
                if selection == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HarnessExperimentalWarning: View {
    let provider: HarnessProvider?

    var body: some View {
        if let provider, provider.isExperimental {
            Label("\(provider.displayName) is experimental. Responses may be slow or unreliable.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ModelChooser: View {
    let providerName: String
    var usesCatalogueDefault = false
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
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled(true)
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
                if !usesCatalogueDefault {
                    modelButton(id: "", name: "\(providerName) default", description: "Use the harness default model.")
                }

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
                if selection == id || (usesCatalogueDefault && selection.isEmpty && models.first(where: \.isDefault)?.id == id) {
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

struct EffortControl: View {
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
        // The icon column matches RuntimeSelectionRow so the label and track align with its text.
        HStack(spacing: 11) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(spacing: 5) {
                HStack {
                    Text("Effort")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(selectionName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection.isEmpty ? Color.secondary : Color.accentColor)
                }

                Group {
                    if choices.count > 1 {
                        EffortTrack(count: choices.count, index: selectedIndex) { selection = choices[$0] }
                            // The drawn track stays a standard slider to assistive clients.
                            .accessibilityRepresentation {
                                Slider(
                                    value: Binding(
                                        get: { Double(selectedIndex) },
                                        set: { selection = choices[Int($0.rounded()).clamped(to: choices.indices)] }
                                    ),
                                    in: 0...Double(choices.count - 1),
                                    step: 1
                                )
                                .accessibilityLabel("Reasoning Effort")
                                .accessibilityValue(selectionName)
                            }
                    } else {
                        Text("Choose a model to tune its effort")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: EffortTrack.height)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A stepped track whose glow and sparkle density grow with the chosen effort.
private struct EffortTrack: View {
    static let height: CGFloat = 22

    let count: Int
    let index: Int
    let select: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spectrum: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.80, green: 0.36, blue: 0.16), location: 0),
                .init(color: Color(red: 0.78, green: 0.42, blue: 0.48), location: 0.3),
                .init(color: Color(red: 0.42, green: 0.48, blue: 0.96), location: 0.58),
                .init(color: Color(red: 0.90, green: 0.96, blue: 1.00), location: 0.8),
                .init(color: Color(red: 0.98, green: 0.56, blue: 0.74), location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let height = Self.height
            let travel = max(proxy.size.width - height, 1)
            let fraction = CGFloat(index) / CGFloat(max(count - 1, 1))
            let knobX = height / 2 + fraction * travel

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))

                ForEach(0..<count, id: \.self) { stop in
                    Circle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: 3, height: 3)
                        .position(x: height / 2 + CGFloat(stop) / CGFloat(max(count - 1, 1)) * travel, y: height / 2)
                }

                ZStack {
                    spectrum
                    Ellipse()
                        .fill(Color.white.opacity(0.2 + 0.5 * fraction))
                        .frame(width: height * 3.2, height: height * 1.3)
                        .blur(radius: 9)
                        .position(x: knobX - height * 0.9, y: height / 2)
                    EffortSparkles(isPaused: reduceMotion || index == 0)
                }
                .mask(alignment: .leading) {
                    Capsule().frame(width: knobX + height / 2)
                }

                spectrum
                    .mask {
                        Circle()
                            .frame(width: height, height: height)
                            .position(x: knobX, y: height / 2)
                    }
                    .overlay {
                        Circle()
                            .fill(Color.white.opacity(0.5))
                            .strokeBorder(Color.white.opacity(0.75), lineWidth: 1)
                            .frame(width: height, height: height)
                            .position(x: knobX, y: height / 2)
                    }
                    // Without flattening, the shadow of the masked gradient smears past the track.
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let position = (value.location.x - height / 2) / travel * CGFloat(count - 1)
                    let next = Int(position.rounded()).clamped(to: 0..<count)
                    guard next != index else { return }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    select(next)
                }
            )
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: index)
        }
        .frame(height: Self.height)
    }
}

private struct EffortSparkles: View {
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isPaused)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                context.blendMode = .plusLighter
                for particle in 0..<54 {
                    let drift = 0.006 + sample(particle, 1) * 0.014
                    let lane = (sample(particle, 2) + time * drift).truncatingRemainder(dividingBy: 1)
                    // The square root crowds sparkles toward the high-effort end.
                    let x = lane.squareRoot() * size.width
                    let sway = sin(time * (0.4 + sample(particle, 3)) + sample(particle, 4) * 6) * 1.5
                    let y = size.height * (0.14 + sample(particle, 5) * 0.72) + sway
                    let twinkle = 0.5 + 0.5 * sin(time * (1.2 + sample(particle, 6) * 2.6) + sample(particle, 7) * 6)
                    let radius = 0.5 + sample(particle, 8) * 1.5
                    context.opacity = 0.2 + 0.75 * twinkle * twinkle
                    context.fill(star(at: CGPoint(x: x, y: y), radius: radius), with: .color(.white))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func star(at center: CGPoint, radius: Double) -> Path {
        guard radius > 1.2 else {
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        let reach = radius * 2.2
        let waist = radius * 0.32
        var path = Path()
        for point in 0..<8 {
            let angle = Double(point) * .pi / 4
            let length = point.isMultiple(of: 2) ? reach : waist
            let vertex = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
            if point == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
        }
        path.closeSubpath()
        return path
    }

    private func sample(_ index: Int, _ salt: UInt64) -> Double {
        var value = UInt64(index) &* 0x9E3779B97F4A7C15 &+ salt &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return Double((value ^ (value >> 31)) & 0xFFFF) / 65535
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
