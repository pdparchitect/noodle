import Foundation
import UWP
import WinSDK
import WinAppSDK
@_spi(WinRTInternal) import WindowsFoundation
@_spi(WinRTImplements) @_spi(WinRTInternal) import WinUI

/// The WinUI application. It hands XAML the metadata of WinUI's own controls, which an app built without the
/// XAML compiler has to do itself: without it WinUI's styles fail to load, as do the names in our markup.
public final class NoodleApp: Application, IXamlMetadataProvider {
    private var window: MainWindow?
    #if NOODLE_DEV_HOOKS
    private var scenario: ScenarioLaunch?
    #endif
    private lazy var controlsMetadata = XamlControlsXamlMetaDataProvider()
    private var metadataProvider: AnyObject?

    /// Starts XAML on this thread the way The Browser Company's SwiftApplication does, rather than through
    /// Application.Start, and then runs a message loop that also serves Foundation's RunLoop and the main queue.
    static func main() {
        do {
            #if NOODLE_DEV_HOOKS
            let scenario = try ScenarioLaunch.load()
            defer { scenario?.removeWorkspace() }
            let pollingScenario = scenario?.replaysTimeline == true
            #else
            guard CommandLine.arguments.dropFirst().first != "--scenario" else { return }
            let pollingScenario = false
            #endif
            // XAML runs on a single-threaded apartment.
            guard RoInitialize(RO_INIT_SINGLETHREADED) >= 0 else { fatalError("Windows Runtime did not start") }
            try WindowsAppRuntime.start()
            let dispatcher = try DispatcherQueueController.createOnCurrentThread()
            let application = NoodleApp()
            #if NOODLE_DEV_HOOKS
            application.scenario = scenario
            #endif
            let xaml = try WindowsXamlManager.initializeForCurrentThread()
            application.dispatcherShutdownMode = .onLastWindowClose
            withExtendedLifetime([dispatcher, application, xaml] as [AnyObject]) { runMessageLoop(pollingScenario: pollingScenario) }
        } catch {
            fatalError("Noodle could not start: \(error)")
        }
    }

    @_spi(WinRTImplements)
    override public func onLaunched(_ args: WinUI.LaunchActivatedEventArgs?) {
        provideMetadata()
        resources.mergedDictionaries.append(XamlControlsResources())
        #if NOODLE_DEV_HOOKS
        window = MainWindow(folder: scenario?.folder ?? Store.defaultFolder, selection: scenario?.selection)
        #else
        window = MainWindow()
        #endif
        window?.activate()
        #if NOODLE_DEV_HOOKS
        if let scenario, let window {
            Task { @MainActor in
                do {
                    try await scenario.play(in: window)
                } catch {
                    print("Scenario replay failed: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }

    /// XAML should ask the application for this metadata through IXamlMetadataProvider, but on Windows App SDK 1.8
    /// it never asked ours, why is not pinned down yet (it keeps the first provider it finds). So it is handed over
    /// through OverrideXamlMetadataProvider, which Microsoft.UI.Xaml.dll exports for its own tests.
    private func provideMetadata() {
        typealias Override = @convention(c) (UnsafeMutableRawPointer?) -> Void
        guard let function = GetProcAddress(GetModuleHandleW("Microsoft.UI.Xaml.dll".wide), "OverrideXamlMetadataProvider"),
              let wrapper = __ABI_Microsoft_UI_Xaml_Markup.IXamlMetadataProviderWrapper(self) else { return }
        metadataProvider = wrapper
        try? wrapper.toABI { unsafeBitCast(function, to: Override.self)(UnsafeMutableRawPointer($0)) }
    }

    public func getXamlType(_ type: TypeName) throws -> AnyIXamlType! { try controlsMetadata.getXamlType(type) }
    public func getXamlType(_ fullName: String) throws -> AnyIXamlType! { try controlsMetadata.getXamlType(fullName) }
    public func getXmlnsDefinitions() throws -> [XmlnsDefinition] { try controlsMetadata.getXmlnsDefinitions() }

    /// Windows messages first, then Foundation's timers and the main queue, then sleep until either has work.
    private static func runMessageLoop(pollingScenario: Bool) {
        typealias PreTranslate = @convention(c) (UnsafePointer<MSG>?) -> Bool
        // WinUI's own keyboard handling, such as accelerators and focus keys, sees each message first.
        let preTranslate = GetProcAddress(LoadLibraryW("Microsoft.UI.Windowing.Core.dll".wide), "ContentPreTranslateMessage")
            .map { unsafeBitCast($0, to: PreTranslate.self) }
        var message = MSG()
        while true {
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
                if message.message == UINT(WM_QUIT) { return }
                if preTranslate?(&message) != true {
                    TranslateMessage(&message)
                    DispatchMessageW(&message)
                }
            }
            var next = RunLoop.main.limitDate(forMode: .default)
            while let date = next, date.timeIntervalSinceNow <= 0 { next = RunLoop.main.limitDate(forMode: .default) }
            let wait = next.map { DWORD(min(max($0.timeIntervalSinceNow * 1000, 0), Double(UInt32.max - 1))) } ?? INFINITE
            // Swift task continuations can reach the main queue without a Win32 message.
            _ = MsgWaitForMultipleObjects(0, nil, false, pollingScenario ? min(wait, 16) : wait, QS_ALLINPUT)
        }
    }
}

private extension String {
    var wide: [UInt16] { Array(utf16) + [0] }
}
