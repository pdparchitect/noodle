import AppKit
import Observation
import NoodleCore

/// Owns one picker/preview session. Generation checks prevent late frames or
/// permission results from reopening a closed panel or crossing conversations.
@MainActor @Observable final class ScreenCaptureModel {
    enum Phase: Equatable { case choosing, loading, live, annotating, closed }
    private(set) var phase: Phase = .choosing { didSet { onCommandsChange?() } }
    var kind: ScreenCaptureKind
    private(set) var sources: [ScreenCaptureSource] = []
    private(set) var thumbnails: [ScreenCaptureSource.ID: CGImage] = [:]
    private(set) var source: ScreenCaptureSource?
    private(set) var image: CGImage?
    private(set) var loadingSources = false
    private(set) var needsPermission = false
    var error: String?
    var region: AttachmentAnnotation.Region?
    var comment = ""
    var onSave: ((CGImage, String, AttachmentAnnotation.Region?, String) throws -> Void)?
    var onFinish: (() -> Void)?
    var onCommandsChange: (() -> Void)?
    @ObservationIgnored private let service: any ScreenCaptureProviding
    @ObservationIgnored private let excludedWindows: () -> [CGWindowID]
    @ObservationIgnored private let currentDisplay: () -> CGDirectDisplayID?
    @ObservationIgnored private var unavailableSources = Set<ScreenCaptureSource.ID>()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(kind: ScreenCaptureKind, service: (any ScreenCaptureProviding)? = nil,
         currentDisplay: @escaping () -> CGDirectDisplayID? = { nil },
         excludedWindows: @escaping () -> [CGWindowID] = { [] }) {
        self.kind = kind; self.service = service ?? ScreenCaptureService(); self.excludedWindows = excludedWindows
        self.currentDisplay = currentDisplay
    }
    var canCapture: Bool { phase == .live && image != nil }
    var canSaveAnnotation: Bool {
        phase == .annotating && region?.isValid == true && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func cancelOperation() -> UUID {
        generation = UUID(); operation?.cancel(); operation = nil
        return generation
    }
    func chooseSources(retryUnavailable: Bool = false) {
        let token = cancelOperation()
        if retryUnavailable { unavailableSources.removeAll() }
        phase = .choosing; source = nil; image = nil; region = nil; comment = ""
        sources = []; thumbnails = [:]; error = nil; loadingSources = false
        needsPermission = !service.hasPermission
        guard !needsPermission else { return }
        loadingSources = true
        let kind = kind, excluded = excludedWindows(), displayID = currentDisplay(), unavailable = unavailableSources
        operation = Task { [weak self, service] in
            do {
                let candidates = ScreenCaptureSource.ordered(try await service.sources(kind: kind, excluding: excluded), on: displayID)
                    .filter { !unavailable.contains($0.id) }
                guard let self, self.generation == token, !Task.isCancelled else { return }
                let request: @Sendable (Int) async -> (Int, CGImage?) = { @MainActor index in
                    guard !Task.isCancelled else { return (index, nil) }
                    let thumbnail = try? await service.thumbnail(for: candidates[index], excluding: excluded)
                    guard !Task.isCancelled, let thumbnail, ScreenCaptureThumbnail.hasContent(thumbnail) else { return (index, nil) }
                    return (index, thumbnail)
                }
                await withTaskGroup(of: (Int, CGImage?).self) { group in
                    let parallelism = min(4, candidates.count)
                    for index in 0..<parallelism { group.addTask { await request(index) } }
                    var scheduled = parallelism, next = 0
                    var completed = Set<Int>(), previews: [Int: CGImage] = [:]
                    for await (index, thumbnail) in group {
                        guard self.generation == token, !Task.isCancelled else { group.cancelAll(); return }
                        completed.insert(index); previews[index] = thumbnail
                        // Publish only validated tiles, in their final order. Slow
                        // thumbnails cannot insert tiles ahead of one being clicked.
                        while completed.remove(next) != nil {
                            if let image = previews.removeValue(forKey: next) {
                                let candidate = candidates[next]
                                self.thumbnails[candidate.id] = image
                                self.sources.append(candidate)
                            }
                            next += 1
                        }
                        if scheduled < candidates.count {
                            let index = scheduled; scheduled += 1
                            group.addTask { await request(index) }
                        }
                    }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.loadingSources = false
                self.needsPermission = !service.hasPermission
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.loadingSources = false; self.error = error.localizedDescription
                self.needsPermission = !service.hasPermission
            }
        }
    }
    func requestPermission() { service.requestPermission(); chooseSources() }
    func permissionMayHaveChanged() {
        if phase == .choosing, needsPermission, service.hasPermission { chooseSources() }
    }
    private func selectionFailed(_ source: ScreenCaptureSource) {
        unavailableSources.insert(source.id)
        chooseSources()
        error = "“\(source.title)” could not provide a live preview and was removed. Restore it, then Refresh to try again."
    }
    func select(_ source: ScreenCaptureSource) {
        let token = cancelOperation()
        self.source = source; image = nil; region = nil; comment = ""; error = nil; phase = .loading
        sources = []; thumbnails = [:]; loadingSources = false
        let excluded = excludedWindows()
        operation = Task { [weak self, service] in
            var feed: (any ScreenCaptureFeed)?
            func makeTimeout() -> Task<Void, Never> {
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self, self.generation == token, self.phase == .loading, self.image == nil else { return }
                    self.selectionFailed(source)
                }
            }
            var timeout = makeTimeout()
            defer { timeout.cancel() }
            do {
                let selectedFeed = try await service.feed(for: source, excluding: excluded)
                feed = selectedFeed
                try Task.checkCancellation()
                try await selectedFeed.start()
                try Task.checkCancellation()
                for try await frame in selectedFeed.frames {
                    guard let self, self.generation == token, !Task.isCancelled else { break }
                    switch frame {
                    case .image(let image):
                        timeout.cancel(); self.image = image; self.phase = .live
                    case .paused:
                        if self.phase == .live { timeout = makeTimeout() }
                        self.image = nil; self.phase = .loading
                    }
                }
                if let self, self.generation == token, !Task.isCancelled {
                    self.selectionFailed(source)
                }
            } catch {
                if let self, self.generation == token, !Task.isCancelled {
                    self.selectionFailed(source)
                }
            }
            // Also stop streams whose asynchronous startup finished after Cancel.
            await feed?.stop()
        }
    }
    func annotate() {
        guard canCapture else { return }
        _ = cancelOperation(); phase = .annotating; region = nil; comment = ""
    }
    func retake() { if let source { select(source) } }
    func capture() { guard canCapture else { return }; save(annotated: false) }
    func saveAnnotation() { guard canSaveAnnotation else { return }; save(annotated: true) }
    private func save(annotated: Bool) {
        guard let image, let source, let onSave else { return }
        do {
            try onSave(image, source.title, annotated ? region : nil, annotated ? comment : "")
            close(); onFinish?()
        } catch { self.error = error.localizedDescription }
    }
    func close() {
        _ = cancelOperation(); phase = .closed; image = nil; sources = []; thumbnails = [:]
        loadingSources = false
        source = nil; region = nil; comment = ""
    }
}
