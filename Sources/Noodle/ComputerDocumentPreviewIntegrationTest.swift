import AppKit
import ComputerBridge
import NoodleCore
import ScreenCaptureKit
import SwiftUI

extension ComputerIntegrationTest {
    /// Opt-in native regression: use the actual attachment owner and installed
    /// Quick Look extension, with disposable files and no NoodleStore or runtime.
    @MainActor static func checkDocumentPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleDocumentPreview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = ComputerReference(computer: .init(id: UUID(), name: "Preview lifecycle test",
            kind: "Shell", state: "Stopped", symbol: "terminal"), terminalID: UUID(),
            terminalPreview: "Saved preview from Noodle Computer\nRepeated opens must keep this view connected.", view: "terminal")
        let data = try JSONEncoder().encode(reference)
        var attachments: [(ConversationAttachment, URL)] = []
        for name in ["Reference.noodlecomputer", "Text.txt", "Unknown.noodle-preview-fixture"] {
            let url = root.appendingPathComponent(name)
            try (name.hasSuffix("noodlecomputer") ? data : Data("Preview lifecycle fixture".utf8)).write(to: url)
            attachments.append((.init(conversationID: UUID(), originalFilename: name, storedFilename: name,
                mediaType: "application/octet-stream", byteCount: Int64(data.count)), url))
        }
        let controller = AttachmentPreviewController()
        var failure: Error?
        controller.reportError = { failure = $0 }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.title = "Attachment preview regression"
        host.contentView = NSHostingView(rootView: AttachmentPreviewHost(controller: controller).frame(width: 600, height: 400))
        host.center(); host.makeKeyAndOrderFront(nil)
        host.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        defer { controller.close(); host.close() }
        try await Task.sleep(for: .seconds(1))
        var opens = 0
        for cycle in 0..<6 {
            for (attachment, url) in attachments {
                controller.show(attachment, url: url) { _, _, _ in }
                guard let panel = controller.panel, panel.isVisible,
                      panel.currentController as? AttachmentPreviewController === controller else {
                    throw ComputerBridgeError("The attachment did not acquire the native preview panel.")
                }
                let item = controller.previewPanel(panel, previewItemAt: 0) as AnyObject
                for _ in 0..<4 {
                    controller.show(attachment, url: url) { _, _, _ in }
                    guard controller.previewPanel(panel, previewItemAt: 0) as AnyObject === item else {
                        throw ComputerBridgeError("Repeated click replaced the in-flight preview item.")
                    }
                    opens += 1
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await Task.sleep(for: .milliseconds(cycle == 0 ? 1500 : 150))
                for _ in 0..<40 where panel.currentPreviewItem?.previewItemURL != url {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard panel.isVisible, panel.currentPreviewItem?.previewItemURL == url else {
                    throw ComputerBridgeError("Quick Look did not display the selected attachment.")
                }
                if cycle == 0, url.pathExtension == "noodlecomputer" {
                    let content = try await SCShareableContent.currentProcess
                    guard let window = content.windows.first(where: { $0.windowID == CGWindowID(panel.windowNumber) }) else {
                        throw ComputerBridgeError("The preview window is unavailable for verification.")
                    }
                    let config = SCStreamConfiguration()
                    config.width = Int(panel.frame.width); config.height = Int(panel.frame.height)
                    config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                    let output = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleDocumentPreview-\(UUID()).png")
                    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw ComputerBridgeError("The preview snapshot could not be encoded.")
                    }
                    try png.write(to: output)
                    print("DOCUMENT PREVIEW SNAPSHOT: \(output.path)")
                }
            }
            controller.close()
            try await Task.sleep(for: .milliseconds(250))
        }
        if let failure { throw failure }
        try await Task.sleep(for: .seconds(1))
        print("DOCUMENT PREVIEW PASSED: \(opens) repeated opens, 18 item selections, 6 closes; no runtime or user workspace")
    }
}
