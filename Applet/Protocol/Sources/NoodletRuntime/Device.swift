import Foundation
import NoodletFormat
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The file dialogs a page opens with `noodle.files`, over the window it is shown in.
@MainActor public enum NoodletFiles {
    public static let limit = 4 * 1_048_576

    /// Asks for a text file: its name and text, or null when the person chose none.
    public static func open(over web: WKWebView) async throws -> Any {
        guard let file = try await choose(over: web) else { return NSNull() }
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= limit else {
            throw AppletError("Text file exceeds 4 MiB.")
        }
        return ["name": file.lastPathComponent, "text": try String(contentsOf: file, encoding: .utf8)]
    }

    /// Saves `text` where the person chooses: whether they did.
    public static func save(_ text: String, named name: String, over web: WKWebView) async throws -> Bool {
        guard text.utf8.count <= limit else { throw AppletError("Text must fit in 4 MiB.") }
        return try await save(text, as: URL(fileURLWithPath: name).lastPathComponent, over: web)
    }

    #if os(macOS)
    private static func choose(over web: WKWebView) async throws -> URL? {
        guard let window = web.window, window.isVisible else {
            throw AppletError("File dialogs require foreground mode. Use noodle.data in background mode.")
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        guard await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.url
    }

    private static func save(_ text: String, as name: String, over web: WKWebView) async throws -> Bool {
        guard let window = web.window, window.isVisible else { throw AppletError("File dialogs require foreground mode.") }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard await panel.beginSheetModal(for: window) == .OK, let file = panel.url else { return false }
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        try text.write(to: file, atomically: true, encoding: .utf8)
        return true
    }
    #else
    private static func choose(over web: WKWebView) async throws -> URL? {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.text, .data], asCopy: true)
        return try await Picker.present(picker, over: web).first
    }

    private static func save(_ text: String, as name: String, over web: WKWebView) async throws -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name.isEmpty ? "Untitled.txt" : name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        return try await !Picker.present(picker, over: web).isEmpty
    }

    /// Waits for the document picker to finish, with what the person picked.
    private final class Picker: NSObject, UIDocumentPickerDelegate {
        private var finish: CheckedContinuation<[URL], Never>?

        static func present(_ picker: UIDocumentPickerViewController, over web: WKWebView) async throws -> [URL] {
            guard var top = web.window?.rootViewController else { throw AppletError("File dialogs need the noodlet on screen.") }
            while let shown = top.presentedViewController { top = shown }
            let delegate = Picker()
            picker.delegate = delegate
            return await withCheckedContinuation { continuation in
                delegate.finish = continuation
                top.present(picker, animated: true)
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
        private func done(_ urls: [URL]) {
            finish?.resume(returning: urls)
            finish = nil
        }
    }
    #endif
}

/// What a device showing a noodlet kept elsewhere adds to its page: file dialogs, and nothing of
/// a window it does not have.
@MainActor public final class NoodletDeviceHost: NoodletPageHost {
    public static let features = ["files"]
    private weak var page: NoodletPage?

    public init(_ page: NoodletPage) {
        self.page = page
        page.host = self
    }

    public func perform(_ operation: String, body: [String: Any]) async throws -> Any {
        guard let web = page?.web else { throw AppletError("Noodlet stopped.") }
        switch operation {
        case "openFile": return try await NoodletFiles.open(over: web)
        case "saveFile":
            guard let text = body["text"] as? String else { throw AppletError("Text must fit in 4 MiB.") }
            return try await NoodletFiles.save(text, named: body["name"] as? String ?? "Untitled.txt", over: web)
        default: throw NoodletPage.unknownOperation
        }
    }
}

/// A page in a SwiftUI view.
#if os(macOS)
public struct NoodletPageView: NSViewRepresentable {
    let page: NoodletPage
    public init(_ page: NoodletPage) { self.page = page }
    public func makeNSView(context: Context) -> WKWebView { page.web }
    public func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
public struct NoodletPageView: UIViewRepresentable {
    let page: NoodletPage
    public init(_ page: NoodletPage) { self.page = page }
    public func makeUIView(context: Context) -> WKWebView { page.web }
    public func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
