import AppKit
import BrowserBridge
import ComputerBridge
import NoodleCore
import ScreenCaptureKit
import SwiftUI

/// Own windows, fake catalogues and a temporary repository; never opens user data.
@MainActor enum BrowserPickerIntegrationTest {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPicker-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root); try repository.prepare()
        let browser = RemoteBrowser(id: UUID(), name: "Browser")
        let computer = RemoteComputer(id: UUID(), name: "My Local Mac", kind: "Mac", state: "Running", symbol: "person.crop.square", colour: 0)
        let browsers = BrowserController(repository: repository, connection: { _ in
            var response = BrowserResponse(); response.browsers = [browser]; return response
        })
        let computers = ComputerController(repository: repository, applicationLookup: { nil }, connection: { _ in
            var response = ComputerResponse(computers: [computer]); response.capabilities = ComputerCapabilities(); return response
        })
        await browsers.refresh(); await computers.refresh()
        let page = NSImage(size: NSSize(width: 800, height: 480), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSString(string: "Project notes").draw(at: NSPoint(x: 40, y: 390), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 38), .foregroundColor: NSColor.black])
            NSString(string: "Quarterly review").draw(at: NSPoint(x: 40, y: 340), withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.gray])
            return true
        }
        let png = NSBitmapImageRep(data: page.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let reference = BrowserReference(browser: browser, tabID: UUID(), url: "https://example.com/notes", title: "Project notes", previewImage: png)
        let file = root.appendingPathComponent("Project notes." + BrowserBuildIdentity.current.fileExtension)
        let bytes = try JSONEncoder().encode(reference); try bytes.write(to: file)
        let attachment = ConversationAttachment(conversationID: UUID(), originalFilename: file.lastPathComponent,
            storedFilename: file.lastPathComponent, mediaType: BrowserReference.mediaType, byteCount: Int64(bytes.count),
            browser: .init(reference: reference, agentID: UUID()))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Browser assignment and attachment verification"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 24) {
                BrowserAssignmentPicker(controller: browsers, selectedIDs: .constant([browser.id]))
                ComputerAssignmentPicker(controller: computers, selectedIDs: .constant([computer.id]))
            }.frame(width: 480)
            AttachmentInlinePreview(attachment: attachment, fileURL: file, shouldLoad: true, isSelected: false, select: {}, preview: {})
        }.padding(20).preferredColorScheme(.dark))
        window.center(); window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(900))
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw BrowserError("Missing fixture window.") }
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * window.backingScaleFactor); config.height = Int(target.frame.height * window.backingScaleFactor)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleBrowserAssignment-" + UUID().uuidString + ".png")
        guard let snapshot = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw BrowserError("Missing fixture snapshot.") }
        try snapshot.write(to: output)
        print("BROWSER PICKER SNAPSHOT: \(output.path)")
    }
}
