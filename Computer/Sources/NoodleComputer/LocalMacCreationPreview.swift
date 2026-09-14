import AppKit
import ComputerCore
import SwiftUI

/// An isolated native form preview. It never presses Create, starts a desktop,
/// registers a service or opens the installed app's computer library.
@MainActor enum LocalMacCreationPreview {
    static func run() async throws {
        guard Bundle.main.bundleIdentifier == "com.pdparchitect.noodle.computer.tests" else {
            throw ComputerError("Use the isolated Computer test build for this preview.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMacForm-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: NewLocalMacView(store: store)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        sheet.contentView = host
        parent.orderBack(nil); parent.beginSheet(sheet, completionHandler: nil)
        defer { parent.endSheet(sheet); sheet.orderOut(nil); parent.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ComputerError("Cannot render the Local Mac form.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ComputerError("Cannot encode the Local Mac form preview.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleLocalMacCreation.png")
        try png.write(to: output)
        guard store.sessions.isEmpty, try store.library.load().isEmpty else {
            throw ComputerError("Form preview unexpectedly created a computer.")
        }
        print("Local Mac creation preview: " + output.path)
    }
}
