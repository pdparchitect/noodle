import AppKit
import NoodleCore
import SwiftUI

struct AppleLocalModelsView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var models: [AppleLocalModel] = []
    @State private var supported = false
    @State private var checking = true
    @State private var importing = false
    @State private var error: String?
    @State private var downloadingID: String?
    @State private var downloadAttempt: UUID?
    @State private var downloadProgress: AppleModelDownloadProgress?
    @State private var downloadTask: Task<AppleLocalModel, Error>?
    @State private var cancelling = false

    private var storage: AppleLocalModelStore { .init(repository: store.repository.rootURL) }
    private var busy: Bool { importing || downloadingID != nil }
    private static let downloadByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        formatter.zeroPadsFractionDigits = true
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Local Models").font(.title2.bold())

                modelContent
                    .frame(maxWidth: .infinity, alignment: .leading)

                recommendedContent

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
        .task {
            do {
                models = try storage.models()
                supported = try await AppleHostProbe().load().localModelsSupported == true
            } catch { self.error = error.localizedDescription }
            checking = false
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
        } else if !models.isEmpty {
            Text("Installed").font(.headline)
            List(models) { model in
                let inUse = store.agents.contains { $0.harnessIdentifier == "apple" && $0.modelIdentifier == model.id }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.name).fontWeight(.medium).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Remove", role: .destructive) { remove(model) }
                        .disabled(inUse || busy)
                        .help(inUse ? "Change bots using this model before removing it." : "Remove Noodle’s copy of this model.")
                }
                .padding(.vertical, 6)
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .frame(height: min(200, CGFloat(models.count) * 64 + 16))
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var recommendedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended").font(.headline)
            ForEach(AppleModelRecommendation.recommended) { recommendation in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(recommendation.name).fontWeight(.medium)
                            HStack(spacing: 8) {
                                Text("4-bit · \(ByteCountFormatter.string(fromByteCount: recommendation.byteCount, countStyle: .file))")
                                    .foregroundStyle(.secondary)
                                Link("Details", destination: recommendation.sourceURL)
                                    .help("Model details and license on Hugging Face")
                            }
                            .font(.caption)
                        }
                        Spacer(minLength: 4)
                        if downloadingID == recommendation.id {
                            Button("Cancel") {
                                cancelling = true
                                downloadTask?.cancel()
                            }
                            .disabled(cancelling)
                        } else if models.contains(where: { $0.sourceRepository == recommendation.repository }) {
                            Text("Installed").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Button("Download") { download(recommendation) }
                                .disabled(!supported || busy)
                        }
                    }
                    if downloadingID == recommendation.id {
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

    private func download(_ recommendation: AppleModelRecommendation) {
        let storage = storage
        let attempt = UUID()
        downloadAttempt = attempt
        downloadingID = recommendation.id
        downloadProgress = nil
        cancelling = false
        error = nil
        let worker = Task.detached {
            try await AppleModelDownloader().download(recommendation, into: storage) { progress in
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
                models = try storage.models()
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
                models = try storage.models()
                await store.runtime.checkExternalInstallation(.apple)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove(_ model: AppleLocalModel) {
        do {
            try storage.remove(id: model.id)
            models = try storage.models()
            Task { await store.runtime.checkExternalInstallation(.apple) }
        } catch { self.error = error.localizedDescription }
    }
}
