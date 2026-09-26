import AppKit
import BrowserBridge
import BrowserCore
import SwiftUI
import NoodleLaunchChecks
import NoodleSettingsUI

/// Arguments the verification scripts pass, matched by digest so a built app never spells them.
/// The first group runs against the packaged release; the rest exist only in development builds.
enum BrowserLaunchCheck {
    static let smokeTest = "e993ae0c24c07a8fbbfc7133af3285da8860a38ff54f34cfa450a0a70447da36"  // --smoke-test
    static let smokeID = "40228d5af4c76b8ab44954591d10dff9a19bb92c3f75621b7088024d5f4c4839"  // --smoke-id
    static let smokePort = "2580591478ab19c1a649d0bc8a13bfd7fe123b4e26ae8462a564cd270bb977b2"  // --smoke-port
    static let restore = "29bd49f2cf8ab06750943309185695f98124d3b11d0a01431979f8dc6baf16dc"  // --restore
    static let cleanup = "0688299ae539e90fa3e970dcb3931d6f8b7c1250f826c11fb0cb92b4427874bf"  // --cleanup
    static let uiTest = "5316570ef39c2b96205d05c38e7ed8c7c68c440f6106cbb7e17bef60f4fc9bc6"  // --browser-ui-test
    static let uiID = "d568d5018b237dfec793eae362ab6230b7f972be46c7e3cba98c36629dd8b1f2"  // --browser-ui-id
    static let cleanupUI = "b2d659d99d371e6058b2c204b2ddc6c2427786b23444ae61a445df8e11bbfd21"  // --cleanup-ui
    #if NOODLE_DEV_HOOKS
    static let serveSmoke = "c9b403b994c0e9d7b5dbf474828f96652ec5eb519afee0406dfd507b007520b8"  // --serve-smoke
    static let pointerOnly = "0df638dd046d3d7cf588fdef105209d3416cf68aa66d195c603de43a3e393301"  // --pointer-only
    static let webMCPDemos = "6710ff36cd45763a3a7719185dd316b603fc3da83bc499df8605db0c66232e93"  // --webmcp-demos
    static let webMCPOnly = "5fadc42340cf84b4331123681e94dffa1e71fa644d48b6dbaeaffca366a28f3d"  // --webmcp-only
    #endif
    static let smoke = LaunchChecks.current.contains(smokeTest), ui = LaunchChecks.current.contains(uiTest)
}

@main struct NoodleBrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var delegate
    @ObservedObject private var visibility = CompanionAppVisibility.shared
    init() {
        if BrowserLaunchCheck.smoke || BrowserLaunchCheck.ui {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
    var body: some Scene {
        Window(BrowserBuildIdentity.current.appName, id: "library") {
            BrowserLibraryView(presentation: delegate.presentation)
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
        if BrowserLaunchCheck.ui {
            let id: UUID
            if LaunchChecks.current.contains(BrowserLaunchCheck.uiID) {
                guard let value = LaunchChecks.current.value(after: BrowserLaunchCheck.uiID).flatMap(UUID.init(uuidString:)) else { exit(1) }
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
        defaults: BrowserLaunchCheck.ui ? nil : .standard)
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
        WindowFocusGuard.shared.start()
        #if NOODLE_DEV_HOOKS
        NSLog("noodle.development-hooks.enabled")
        #endif
        CompanionAppVisibility.shared.start(permitsDock: !BrowserLaunchCheck.smoke && !BrowserLaunchCheck.ui)
        runtime.showBrowser = { [weak self] id in self?.showBrowser(id) }
        runtime.willRemoveBrowser = { [weak self] id in
            guard let self else { return }
            if self.presentation.selection == id { self.presentation.selection = nil }
        }
        if BrowserLaunchCheck.smoke {
            Task { await BrowserSmokeTest.runAndExit() }; return
        }
        if BrowserLaunchCheck.ui {
            Task { await BrowserUITest.runAndExit(delegate: self) }; return
        }
        runtime.startServer()
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true, !externalLaunch {
            DispatchQueue.main.async { if !self.externalLaunch { self.reopenLibrary() } }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !BrowserLaunchCheck.smoke, !BrowserLaunchCheck.ui else { return }
        // Match Computer/Applet: quiet provider startup never prompts for updates.
        BrowserUpdater.shared.start()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        externalLaunch = true
        for url in urls {
            if url == BrowserLaunch.backgroundURL { continue }
            if url == BrowserLaunch.updateCheckURL() {
                reopenLibrary()
                BrowserUpdater.shared.start(); BrowserUpdater.shared.check()
                continue
            }
            // A link to a browser, and to the tab a bot shared if it is still open.
            guard BrowserLink.build(in: url) == .current, let target = BrowserLink.target(in: url) else { continue }
            if let tab = target.tab, (try? runtime.tab(browserID: target.browser, tabID: tab)) != nil {
                presentation.selection = target.browser; presentation.selectTab(tab)
                reopenLibrary()
            } else {
                showBrowser(target.browser)
            }
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
