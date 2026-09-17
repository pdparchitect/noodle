import AppKit
import BrowserBridge
import BrowserCore
import SwiftUI
import NoodleSettingsUI

@main struct NoodleBrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var delegate
    @ObservedObject private var visibility = CompanionAppVisibility.shared
    init() {
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--browser-ui-test") {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
    var body: some Scene {
        Window(BrowserBuildIdentity.current.appName, id: "library") {
            BrowserLibraryView(presentation: delegate.presentation)
                .companionSettingsAccess()
                .frame(minWidth: 850, minHeight: 580)
                .preferredColorScheme(.dark)
                .background(BrowserLibraryWindowHost(library: delegate.libraryWindow))
                .handlesExternalEvents(preferring: [], allowing: [])
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(after: .appSettings) { BrowserCheckForUpdatesButton() }
            CommandGroup(replacing: .appInfo) {
                Button("About \(BrowserBuildIdentity.current.appName)") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: BrowserBuildIdentity.current.appName])
                }
            }
            CommandGroup(replacing: .help) {
                Button("\(BrowserBuildIdentity.current.appName) Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/pdparchitect/noodle")!)
                }
            }
            BrowserCommands(delegate: delegate, presentation: delegate.presentation)
        }
        Settings { BrowserSettingsView().preferredColorScheme(.dark) }
            .windowResizability(.contentSize)
            .handlesExternalEvents(matching: [])
        MenuBarExtra(isInserted: $visibility.showMenuBar) {
            BrowserMenu(library: delegate.library, delegate: delegate)
        } label: {
            CompanionMenuBarLabel(BrowserBuildIdentity.current.appName)
        }
        .handlesExternalEvents(matching: [])
    }
}

@MainActor final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    let library: BrowserLibrary
    override init() {
        if CommandLine.arguments.contains("--browser-ui-test") {
            let args = CommandLine.arguments
            let id: UUID
            if let index = args.firstIndex(of: "--browser-ui-id") {
                guard index + 1 < args.count, let value = UUID(uuidString: args[index + 1]) else { exit(1) }
                id = value
            } else { id = UUID() }
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BrowserUI/" + id.uuidString)
            library = BrowserLibrary(root: root)
        } else { library = BrowserLibrary() }
        super.init()
    }
    lazy var runtime = BrowserRuntime(library: library)
    lazy var presentation = BrowserPresentation(library: library, runtime: runtime,
        defaults: CommandLine.arguments.contains("--browser-ui-test") ? nil : .standard)
    let libraryWindow = BrowserLibraryWindow()
    var openLibrary: (() -> Void)? {
        didSet {
            if needsLibrary, openLibrary != nil {
                needsLibrary = false
                DispatchQueue.main.async { [weak self] in self?.reopenLibrary() }
            }
        }
    }
    private var needsLibrary = false
    private var externalLaunch = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        CompanionAppVisibility.shared.start(permitsDock: !CommandLine.arguments.contains { $0.hasSuffix("-test") })
        runtime.showBrowser = { [weak self] id in self?.showBrowser(id) }
        runtime.willRemoveBrowser = { [weak self] id in
            guard let self else { return }
            if self.presentation.selection == id { self.presentation.selection = nil }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            Task { await BrowserSmokeTest.runAndExit() }; return
        }
        if CommandLine.arguments.contains("--browser-ui-test") {
            Task { await BrowserUITest.runAndExit(delegate: self) }; return
        }
        runtime.startServer()
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true, !externalLaunch {
            DispatchQueue.main.async { if !self.externalLaunch { self.reopenLibrary() } }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--smoke-test"), !CommandLine.arguments.contains("--browser-ui-test") else { return }
        // Match Computer/Applet: quiet provider startup never prompts for updates.
        BrowserUpdater.shared.start()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        externalLaunch = true
        for url in urls {
            if url == BrowserLaunch.backgroundURL { continue }
            if url.isFileURL {
                do {
                    let reference = try BrowserReference.read(url)
                    let tabID = try runtime.openReference(reference)
                    presentation.selection = reference.browser.id; presentation.selectTab(tabID)
                    reopenLibrary()
                } catch { runtime.failure = error.localizedDescription; reopenLibrary() }
                continue
            }
            guard url.scheme == BrowserBuildIdentity.current.urlScheme,
                  let id = url.host.flatMap(UUID.init(uuidString:)) else { continue }
            showBrowser(id)
        }
    }
    func showBrowser(_ id: UUID) {
        do { _ = try library.profile(id); presentation.selection = id; try runtime.openBrowser(id) }
        catch { runtime.failure = error.localizedDescription }
        reopenLibrary()
    }
    func reopenLibrary() {
        if !libraryWindow.focus() {
            if let openLibrary { openLibrary() } else { needsLibrary = true }
        }
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { reopenLibrary(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { runtime.shutdown() }
}

@MainActor private struct BrowserCommands: Commands {
    let delegate: BrowserAppDelegate
    @ObservedObject var presentation: BrowserPresentation
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let action = openWindow
        let _ = delegate.openLibrary = { action(id: "library") }
        CommandGroup(replacing: .newItem) {
            Button("New Browser…") { delegate.reopenLibrary(); delegate.presentation.showingNew = true }.keyboardShortcut("n")
            Button("New Tab") { delegate.presentation.newTab(); delegate.reopenLibrary() }.keyboardShortcut("t")
                .disabled(delegate.presentation.selection == nil)
        }
        CommandMenu("Browser") {
            Button("Open Browser Window") { delegate.reopenLibrary() }.keyboardShortcut("0")
            Divider()
            Button("Open Location…") { delegate.reopenLibrary(); delegate.presentation.focusAddress() }.keyboardShortcut("l")
            Button("Back") { delegate.presentation.currentTab?.web.goBack() }.keyboardShortcut("[")
            Button("Forward") { delegate.presentation.currentTab?.web.goForward() }.keyboardShortcut("]")
            Button("Reload") { delegate.presentation.currentTab?.web.reload() }.keyboardShortcut("r")
            Divider()
            Button("History") { delegate.reopenLibrary(); delegate.presentation.mode = .history }.keyboardShortcut("y")
            Button("Bookmarks") { delegate.reopenLibrary(); delegate.presentation.mode = .bookmarks }.keyboardShortcut("b", modifiers: [.command, .option])
            Button("Add Bookmark…") { delegate.reopenLibrary(); delegate.presentation.bookmarkCurrentPage() }.keyboardShortcut("d")
            Button("Downloads") { delegate.reopenLibrary(); delegate.presentation.mode = .downloads }
        }
    }
}
