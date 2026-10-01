import Foundation
import NoodletFormat
import Surface
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

    /// A download's suggested name as a plain file name, never a path.
    nonisolated static func safeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty path would name the current directory.
        guard !trimmed.isEmpty else { return "download" }
        let last = URL(fileURLWithPath: trimmed).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return last.isEmpty || last == "/" || last.hasPrefix(".") ? "download" : last
    }

    /// A private file WebKit writes a download to before it reaches the person's folders.
    nonisolated static func stagingURL(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoodletDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(safeName(name))
    }

    /// Opens a web link in the person's browser, only while they can see the noodlet.
    static func openExternally(_ url: URL, over web: WKWebView) -> Bool {
        #if os(macOS)
        guard web.window?.isVisible == true else { return false }
        return NSWorkspace.shared.open(url)
        #else
        guard let scene = web.window?.windowScene else { return false }
        scene.open(url, options: nil)
        return true
        #endif
    }

    #if os(macOS)
    /// Asks where a download goes, before WebKit starts writing it.
    static func chooseDestination(named name: String, over web: WKWebView) async throws -> URL? {
        guard let window = web.window, window.isVisible else {
            throw AppletError("Downloads need the noodlet in the foreground.")
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = safeName(name)
        guard await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.url
    }

    /// Puts a finished download where the person chose; the save panel already agreed to replace it.
    static func export(_ staged: URL, to destination: URL) throws {
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: staged, to: destination)
    }

    /// The files a page's `<input type=file>` gets: what the person picks, as the input allows.
    static func chooseUploads(_ parameters: WKOpenPanelParameters, over web: WKWebView) async -> [URL]? {
        guard let window = web.window, window.isVisible else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        guard await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.urls
    }
    #else
    /// Hands a finished download to the document picker, where the person chooses where it goes.
    static func export(_ staged: URL, over web: WKWebView) async throws -> Bool {
        let picker = UIDocumentPickerViewController(forExporting: [staged], asCopy: true)
        return try await !Picker.present(picker, over: web).isEmpty
    }
    #endif

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
    /// What was typed so far, played into the page one after another.
    private var typing: Task<Void, Never>?
    #if os(iOS)
    private lazy var keyboard = PageKeyboard { [weak self] in self?.type($0) }
    #endif

    public init(_ page: NoodletPage) {
        self.page = page
        page.host = self
    }

    /// Plays a key or text into the page as a keyboard's key events, after what came before it.
    public func type(_ input: SurfaceInput) {
        guard let page, let script = PageKeys.script(for: input) else { return }
        let previous = typing
        typing = Task { [weak page] in
            await previous?.value
            _ = try? await page?.evaluate(script)
        }
    }

    /// Returns once everything typed so far has reached the page.
    public func typed() async { await typing?.value }

    #if os(iOS)
    /// Shows or hides the phone's keyboard, which types into the page.
    public func toggleKeyboard() {
        guard let web = page?.web else { return }
        if keyboard.superview !== web { web.addSubview(keyboard) }
        if keyboard.isFirstResponder { keyboard.resignFirstResponder() } else { keyboard.becomeFirstResponder() }
    }
    #endif

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

#if os(iOS)
/// Takes what is typed on the phone's keyboard for a page that listens for keys, as the live view does.
private final class PageKeyboard: UIView, UIKeyInput {
    private let type: (SurfaceInput) -> Void
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no

    init(type: @escaping (SurfaceInput) -> Void) {
        self.type = type
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) { type(text == "\n" ? .key(.enter) : .text(text)) }
    func deleteBackward() { type(.key(.backspace)) }
}
#endif

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
