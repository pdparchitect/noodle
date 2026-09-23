import AppKit
import NoodleCore
import SwiftUI
import NoodleRuntime

public struct AppleLocalModelsView: View {
    let store: any BotSettingsHost
    @Environment(\.dismiss) private var dismiss
    @State private var models: [AppleLocalModel] = []
    @State private var unreadable: [AppleLocalModel] = []
    @State private var checkedSupport: Bool?
    @State private var checked = false
    @State private var importing = false
    @State private var error: String?
    @State private var downloadingID: String?
    @State private var downloadAttempt: UUID?
    @State private var downloadProgress: AppleModelDownloadProgress?
    @State private var downloadTask: Task<AppleLocalModel, Error>?
    @State private var cancelling = false
    @State private var modelUsageID: String?
    @State private var editingAgent: AgentRecord?
    @State private var returnToModelID: String?
    @State private var modelPendingRemoval: AppleLocalModel?
    @State private var installedHeight: CGFloat = 0
    private let checkSupport: @MainActor () async throws -> Bool

    init(store: any BotSettingsHost, checkSupport: @escaping @MainActor () async throws -> Bool = {
        try await AppleHostProbe.load().localModelsSupported == true
    }) {
        self.store = store
        self.checkSupport = checkSupport
    }

    private var storage: AppleLocalModelStore { .init(repository: store.repository.rootURL) }
    private var busy: Bool { importing || downloadingID != nil }
    private var installed: [AppleLocalModel] { models + unreadable }
    private var available: [AppleDownloadableModel] {
        AppleDownloadableModel.available.filter { downloadable in
            !models.contains { $0.sourceRepository == downloadable.repository }
        }
    }
    // Open with the runtime's last known answer; the fresh check replaces it.
    private var knownSupport: Bool? { checkedSupport ?? store.runtime.appleLocalModelsSupported }
    private var supported: Bool { knownSupport == true }
    private var checking: Bool { !checked && knownSupport == nil }
    private static let downloadByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        formatter.zeroPadsFractionDigits = true
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Local Models").font(.title2.bold())

                modelContent
                    .frame(maxWidth: .infinity, alignment: .leading)

                availableContent

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            Divider()
            HStack {
                Button("Import Model…", action: importModel).disabled(checking || !supported || busy)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(busy)
        .onDisappear { downloadTask?.cancel() }
        .sheet(item: $editingAgent, onDismiss: {
            if let id = returnToModelID, installed.contains(where: { $0.id == id }) { modelUsageID = id }
            returnToModelID = nil
        }) { agent in
            store.botRuntimeEditor(agent)
                .noodleSheetSizing(animated: true)
        }
        .alert("Remove Model?", isPresented: Binding(
            get: { modelPendingRemoval != nil },
            set: { if !$0 { modelPendingRemoval = nil } }
        ), presenting: modelPendingRemoval) { model in
            Button("Remove", role: .destructive) { remove(model) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { model in
            Text("Noodle’s copy of “\(model.name)” will be deleted. You can download or import it again later.")
        }
        // Listing is a cheap local read; have it ready for the first frame.
        .onAppear {
            do { try reload() } catch { self.error = error.localizedDescription }
        }
        .task {
            do {
                let result = try await checkSupport()
                checkedSupport = result
                store.runtime.recordAppleLocalModelsSupport(result)
            } catch { self.error = error.localizedDescription }
            checked = true
        }
    }

    @ViewBuilder
    private var modelContent: some View {
        if checking || importing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(importing ? "Importing model files…" : "Checking local model support…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if !supported {
            Text("Requires macOS 27 and a Noodle build with local model support.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !installed.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Installed").font(.headline)
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(installed) { model in
                            let users = botsUsing(model)
                            let source = AppleDownloadableModel.available.first { $0.repository == model.sourceRepository }
                            modelRow(name: model.name, summary: source?.summary, byteCount: model.byteCount, sourceURL: source?.sourceURL) {
                                Button("Remove", role: .destructive) { requestRemoval(model) }
                                    .disabled(busy)
                                    .help(users.isEmpty ? "Remove Noodle’s copy of this model."
                                          : "Used by \(users.map(\.displayName).joined(separator: ", ")).")
                                    .popover(isPresented: Binding(
                                        get: { modelUsageID == model.id },
                                        set: { if !$0, modelUsageID == model.id { modelUsageID = nil } }
                                    ), arrowEdge: .trailing) {
                                        AppleModelUsagePopover(model: model, agents: botsUsing(model), edit: { agent in
                                            returnToModelID = model.id
                                            modelUsageID = nil
                                            editingAgent = agent
                                        }, remove: { requestRemoval(model) }, close: { modelUsageID = nil })
                                    }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { installedHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Leave the sheet room for the models still on offer.
                .frame(height: min(installedHeight, max(200, 560 - CGFloat(available.count) * 96)))
            }
        }
    }

    @ViewBuilder
    private var availableContent: some View {
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Available").font(.headline)
                ForEach(available) { downloadable in
                    VStack(alignment: .leading, spacing: 8) {
                        modelRow(name: downloadable.name, summary: downloadable.summary, byteCount: downloadable.byteCount,
                                 sourceURL: downloadable.sourceURL,
                                 recommended: downloadable.id == AppleDownloadableModel.recommended()?.id) {
                            if downloadingID == downloadable.id {
                                Button("Cancel") {
                                    cancelling = true
                                    downloadTask?.cancel()
                                }
                                .disabled(cancelling)
                            } else {
                                Button("Download") { download(downloadable) }
                                    .disabled(!supported || busy)
                            }
                        }
                        if downloadingID == downloadable.id {
                            VStack(alignment: .leading, spacing: 5) {
                                ProgressView(value: downloadProgress?.fraction ?? 0)
                                Text(downloadStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    /// A model from the catalogue carries its summary and source; an imported one has only its name and size.
    private func modelRow(name: String, summary: String?, byteCount: Int64, sourceURL: URL?, recommended: Bool = false,
                          @ViewBuilder action: () -> some View) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.medium).lineLimit(2)
                    if recommended {
                        Text("Recommended").font(.caption2).foregroundStyle(.tint)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: Capsule())
                            .help("The best fit for this Mac’s memory.")
                    }
                }
                if let summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(sourceURL == nil ? size : "4-bit · \(size)").foregroundStyle(.secondary)
                    if let sourceURL {
                        Link("Details", destination: sourceURL)
                            .help("Model details and license on Hugging Face")
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 4)
            action()
        }
    }

    private var downloadStatus: String {
        if cancelling { return "Cancelling…" }
        guard let progress = downloadProgress else { return "Preparing download…" }
        switch progress.phase {
        case .downloading:
            let completed = Self.downloadByteFormatter.string(fromByteCount: progress.completedBytes)
            let total = Self.downloadByteFormatter.string(fromByteCount: progress.totalBytes)
            return "Downloading \(completed) of \(total)…"
        case .verifying: return "Verifying model files…"
        case .importing: return "Importing model files…"
        }
    }

    private func download(_ downloadable: AppleDownloadableModel) {
        let storage = storage
        let attempt = UUID()
        downloadAttempt = attempt
        downloadingID = downloadable.id
        downloadProgress = nil
        cancelling = false
        error = nil
        let worker = Task.detached {
            try await AppleModelDownloader().download(downloadable, into: storage) { progress in
                Task { @MainActor in
                    guard downloadAttempt == attempt else { return }
                    downloadProgress = progress
                }
            }
        }
        downloadTask = worker
        Task {
            defer { downloadingID = nil; downloadAttempt = nil; downloadTask = nil; downloadProgress = nil; cancelling = false }
            do {
                _ = try await worker.value
                try reload()
                await store.runtime.checkExternalInstallation(.apple)
            } catch {
                if !(error is CancellationError) && !worker.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.title = "Import MLX Model"
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let access = source.startAccessingSecurityScopedResource()
        let storage = storage
        importing = true
        error = nil
        Task {
            defer { if access { source.stopAccessingSecurityScopedResource() }; importing = false }
            do {
                _ = try await Task.detached { try storage.importModel(from: source) }.value
                try reload()
                await store.runtime.checkExternalInstallation(.apple)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func reload() throws {
        models = try storage.models()
        unreadable = try storage.unreadableModels()
    }

    private func botsUsing(_ model: AppleLocalModel) -> [AgentRecord] {
        store.agents.filter { $0.harnessIdentifier == "apple" && $0.modelIdentifier == model.id }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func requestRemoval(_ model: AppleLocalModel) {
        guard !busy else { return }
        guard botsUsing(model).isEmpty else {
            modelUsageID = model.id
            return
        }
        modelUsageID = nil
        modelPendingRemoval = model
    }

    private func remove(_ model: AppleLocalModel) {
        modelPendingRemoval = nil
        guard !busy else { return }
        let users = botsUsing(model)
        guard users.isEmpty else {
            modelUsageID = model.id
            return
        }
        modelUsageID = nil
        do {
            try storage.remove(id: model.id)
            try reload()
            Task { await store.runtime.checkExternalInstallation(.apple) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct AppleModelUsagePopover: View {
    let model: AppleLocalModel
    let agents: [AgentRecord]
    let edit: (AgentRecord) -> Void
    let remove: () -> Void
    let close: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(agents.isEmpty ? "Model Unassigned" : "Model in Use").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Close").help("Close")
            }
            Text(model.name).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agents.isEmpty {
                Text("No bots use this model.").font(.callout)
                Button("Remove Model", role: .destructive, action: remove)
            } else {
                Text("Choose another model for these bots before removing it.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(agents) { agent in
                            HStack(spacing: 10) {
                                BotAvatar(agent: agent, size: 28)
                                Text(agent.displayName).lineLimit(2)
                                Spacer(minLength: 8)
                                Button("Edit") { edit(agent) }
                                    .accessibilityLabel("Edit \(agent.displayName)")
                                    .help("Edit \(agent.displayName)’s model settings")
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
                .frame(height: min(240, CGFloat(agents.count) * 44))
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
