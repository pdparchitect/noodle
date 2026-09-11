import AppKit
import QuickLookUI
import ScreenCaptureKit
import NoodleCore

/// Foreground, opt-in regression test. Uses the production controller and the
/// real AppKit event queue. Never refocuses Quick Look after Save or Escape.
/// Captures only this disposable fixture application's windows at 60 fps.
@MainActor extension AnnotationFixture {
    func runVisualCancellation() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-visual-\(UUID())")
        repository = WorkspaceRepository(rootURL: directory)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Visual fixture — never launched")
        let diff = try repository.importAttachment(data: Data("""
        diff --git a/hello.py b/hello.py
        --- a/hello.py
        +++ b/hello.py
        @@ -1 +1 @@
        -print('Hello')
        +print('Hello, world')
        """.utf8), originalFilename: "Review.diff", into: bot.conversation.id, mediaType: "text/plain")
        let host = window("Isolated annotation test", controller: first)
        try await focus(host)
        show(diff, on: first)
        try await visualUntil("Quick Look must open and acquire focus") { first.canAnnotate }
        try await wait(1.2)
        guard let preview = first.panel else { throw VisualCheckFailure("Missing Quick Look panel") }
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-recording-\(UUID())")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        print("VISUAL_EVIDENCE: \(evidence.path)")
        let recording = AnnotationVisualRecorder(controller: first, directory: evidence)
        try await recording.start()
        var failure: Error?
        do {
            for attempt in 1...6 {
                recording.mark("attempt \(attempt): select native diff text")
                guard NSApp.sendAction(NSSelectorFromString("selectAll:"), to: nil, from: nil) else {
                    throw VisualCheckFailure("Native diff selection failed")
                }
                try await key(0, characters: "a", flags: [.command, .shift], window: preview)
                try await visualUntil("Annotation editor must become key") { first.commentInput?.window?.isKeyWindow == true }
                guard first.pending?.quote?.contains("Hello, world") == true else {
                    throw VisualCheckFailure("Selected text must come from native Quick Look")
                }
                try await wait(0.7)
                let saving = attempt.isMultiple(of: 3)
                first.commentInput?.string = saving ? "Saved visual regression comment \(attempt)" : "Discard me"
                recording.mark("attempt \(attempt): \(saving ? "Save" : "Escape") queued")
                let closesBefore = recording.previewCloseCount
                let invalidSamplesBefore = recording.previewInvalidSamples
                try await key(saving ? 36 : 53, characters: saving ? "\r" : "\u{1b}",
                    flags: saving ? .command : [], window: first.commentInput!.window!)
                // Observe the whole animation and delayed callbacks even on
                // failure. Do not terminate at the first missing/hidden panel.
                try await wait(1.8)
                recording.mark("attempt \(attempt): observation complete")
                guard preview.isVisible, preview.isKeyWindow, first.canAnnotate,
                      preview.currentPreviewItem?.previewItemURL == repository.attachmentFileURL(diff),
                      recording.previewCloseCount == closesBefore,
                      recording.previewInvalidSamples == invalidSamplesBefore else {
                    throw VisualCheckFailure("\(saving ? "Save" : "Escape") closed or invalidated native Quick Look on attempt \(attempt); see recording and lifecycle.jsonl")
                }
            }
            recording.mark("separate Escape: close Quick Look")
            try await key(53, characters: "\u{1b}", window: preview)
            try await wait(1.5)
            guard !preview.isVisible, first.currentURL == nil else {
                throw VisualCheckFailure("Separate Escape must leave Quick Look closed")
            }
            // Same host after closing: reopen without any test-side refocus.
            recording.mark("reopen attachment after close")
            show(diff, on: first)
            try await visualUntil("Reopened preview must be usable") { first.canAnnotate }
            try await wait(0.7)
            recording.mark("Cmd-W: close Quick Look")
            try await key(13, characters: "w", flags: .command, window: preview)
            try await wait(1.5)
            guard !preview.isVisible, first.currentURL == nil, stored.count == 2 else {
                throw VisualCheckFailure("Close or saved annotation count is incorrect")
            }
            let messages = try repository.loadMessages(conversationID: bot.conversation.id)
            guard messages.isEmpty else { throw VisualCheckFailure("Fixture must never send messages") }
        } catch { failure = error; recording.mark("FAILED: \(error.localizedDescription)") }
        try await recording.stop()
        if let failure { throw failure }
    }

    private func visualUntil(_ description: String, condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await wait(0.05)
        }
        throw VisualCheckFailure(description)
    }
}

private struct VisualCheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor private final class AnnotationVisualRecorder: NSObject, @preconcurrency SCRecordingOutputDelegate {
    let controller: AttachmentPreviewController
    let directory: URL
    let startTime = ProcessInfo.processInfo.systemUptime
    var stream: SCStream?
    var output: SCRecordingOutput?
    var finished = false
    var recordingError: Error?
    var timer: Timer?
    var rows: [[String: Any]] = []
    var previewCloseCount = 0
    var previewInvalidSamples = 0
    var lastState = ""

    init(controller: AttachmentPreviewController, directory: URL) {
        self.controller = controller; self.directory = directory
    }

    func start() async throws {
        // Public API restricted to the current process; no screen permission
        // request and no other application's content in the video.
        let content = try await SCShareableContent.currentProcess
        guard let application = content.applications.first(where: { $0.processID == getpid() }),
              let display = content.displays.first(where: { $0.frame.intersects(controller.panel!.frame) }) ?? content.displays.first else {
            throw VisualCheckFailure("Own-process capture is unavailable")
        }
        let filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.frame.width); config.height = Int(display.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false; config.capturesAudio = false; config.includeChildWindows = true
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = directory.appendingPathComponent("native-cancellation.mp4")
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        self.stream = stream; self.output = output
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSPopover.willCloseNotification,
                     NSPopover.didCloseNotification, NSPopover.didShowNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(observed(_:)), name: name, object: nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        try await stream.startCapture()
        mark("capture started")
    }

    func mark(_ event: String) {
        rows.append(["seconds": ProcessInfo.processInfo.systemUptime - startTime, "event": event])
        print("VISUAL: \(event)")
        sample()
    }

    @objc private func observed(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification, notification.object as? NSWindow === controller.panel {
            previewCloseCount += 1
        }
        let number = (notification.object as? NSWindow)?.windowNumber ?? -1
        mark("\(notification.name.rawValue) window=\(number)")
    }

    private func sample() {
        let panel = controller.panel
        if panel?.isVisible != true || controller.currentURL == nil ||
            panel?.currentController as? AttachmentPreviewController !== controller {
            previewInvalidSamples += 1
        }
        let windows: [[String: Any]] = NSApp.windows.map { window in
            ["id": window.windowNumber, "class": String(describing: type(of: window)),
             "visible": window.isVisible, "key": window.isKeyWindow, "alpha": window.alphaValue,
             "parent": window.parent?.windowNumber ?? -1, "frame": NSStringFromRect(window.frame)]
        }
        let state: [String: Any] = ["windows": windows, "previewVisible": panel?.isVisible == true,
            "previewKey": panel?.isKeyWindow == true, "item": controller.currentURL != nil,
            "ownsPreview": panel?.currentController as? AttachmentPreviewController === controller,
            "canAnnotate": controller.canAnnotate, "popover": controller.commentPopover != nil,
            "firstResponder": panel?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"]
        guard let bytes = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
              let text = String(data: bytes, encoding: .utf8), text != lastState else { return }
        lastState = text
        rows.append(["seconds": ProcessInfo.processInfo.systemUptime - startTime, "state": state])
    }

    func stop() async throws {
        mark("capture stopping")
        timer?.invalidate(); timer = nil
        NotificationCenter.default.removeObserver(self)
        try await stream?.stopCapture()
        for _ in 0..<100 where !finished && recordingError == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = try rows.map { try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
            .reduce(into: Data()) { $0.append($1); $0.append(0x0a) }
        try data.write(to: directory.appendingPathComponent("lifecycle.jsonl"))
        if let recordingError { throw recordingError }
        guard finished else { throw VisualCheckFailure("Recording did not finish") }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished = true }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { recordingError = error }
}
