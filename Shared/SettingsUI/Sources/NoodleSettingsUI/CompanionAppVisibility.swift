import AppKit
import SwiftUI

/// Each companion uses its own defaults domain. Keep Applet's existing menu key.
@MainActor public final class CompanionAppVisibility: ObservableObject {
    public static let shared = CompanionAppVisibility()
    public static let dockKey = "showInDock"
    public static let menuBarKey = "showMenuBar"

    @Published private var dockVisible: Bool
    @Published private var menuBarVisible: Bool

    public var showInDock: Bool {
        get { dockVisible }
        set {
            guard newValue != dockVisible else { return }
            dockVisible = newValue
            defaults.set(newValue, forKey: Self.dockKey)
            if started { applyDockVisibility() }
        }
    }
    public var showMenuBar: Bool {
        get { menuBarVisible }
        set {
            // MenuBarExtra can write its current insertion state during scene
            // reconciliation. Publishing that unchanged value loops the app graph.
            guard newValue != menuBarVisible else { return }
            menuBarVisible = newValue
            defaults.set(newValue, forKey: Self.menuBarKey)
        }
    }

    private let defaults: UserDefaults
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let currentPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private var started = false
    private var permitsDock = true
    private var updateObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard,
                setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = CompanionAppVisibility.setApplicationPolicy,
                currentPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy = { NSApplication.shared.activationPolicy() }) {
        self.defaults = defaults
        self.setPolicy = setPolicy
        self.currentPolicy = currentPolicy
        dockVisible = defaults.object(forKey: Self.dockKey) as? Bool ?? true
        menuBarVisible = defaults.object(forKey: Self.menuBarKey) as? Bool ?? false
    }

    /// Call after AppKit launches, including launches that create no windows.
    public func start(permitsDock: Bool = true) {
        self.permitsDock = permitsDock
        started = true
        applyDockVisibility()
        // Launch Services resets a running app to its Info.plist type whenever it
        // delivers an open or reopen request, including background provider starts.
        if updateObserver == nil {
            updateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreDockVisibility() }
            }
        }
    }

    private var policy: NSApplication.ActivationPolicy { showInDock && permitsDock ? .regular : .accessory }

    private func applyDockVisibility() { setPolicy(policy) }

    func restoreDockVisibility() {
        if started, currentPolicy() != policy { applyDockVisibility() }
    }

    public static func setApplicationPolicy(_ policy: NSApplication.ActivationPolicy) {
        let app = NSApplication.shared
        guard app.activationPolicy() != policy else { return }
        let active = app.isActive
        let window = app.keyWindow
        guard app.setActivationPolicy(policy) else { return }
        // Changing policy must not strand the Settings window behind other apps.
        if active {
            app.unhide(nil)
            window?.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor public struct CompanionVisibilitySettings: View {
    @ObservedObject private var visibility: CompanionAppVisibility

    public init(visibility: CompanionAppVisibility? = nil) { self.visibility = visibility ?? .shared }

    public var body: some View {
        Section {
            Toggle("Show in Dock", isOn: $visibility.showInDock)
                .help("Show the app in the Dock and app switcher.")
            Toggle("Show in Menu Bar", isOn: $visibility.showMenuBar)
        }
    }
}

/// The packaged symbol SVG supplies a monochrome, appearance-aware status icon.
public struct CompanionMenuBarLabel: View {
    private let name: String
    // Keep the image identity stable when SwiftUI rebuilds its scene list.
    private static let image: NSImage? = {
        let image = Bundle.main.url(forResource: "AppSymbol", withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
        image?.size = NSSize(width: 24, height: 24)
        image?.isTemplate = true
        return image
    }()

    public init(_ name: String) { self.name = name }

    public var body: some View {
        if let image = Self.image {
            Image(nsImage: image).accessibilityLabel(name)
        } else {
            Text(name)
        }
    }
}

public struct CompanionMenuSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    public init() {}

    public var body: some View {
        Button("Settings…") {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }.keyboardShortcut(",")
    }
}

public extension View {
    /// Keep preferences reachable even when the user disables both entry points.
    func companionSettingsAccess() -> some View { modifier(CompanionSettingsAccess()) }
}

private struct CompanionSettingsAccess: ViewModifier {
    @ObservedObject private var visibility = CompanionAppVisibility.shared

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .automatic) {
                if !visibility.showInDock && !visibility.showMenuBar { CompanionSettingsButton() }
            }
        }
    }
}

/// The same fallback for toolbars that must order it themselves: a root-level
/// item lands ahead of a column's own items, so declare this one last instead.
/// A toolbar without its own flexible space passes `.flexible` to push the item
/// to the window's trailing edge; items otherwise pack against the sidebar.
@available(macOS 26.0, *)
@MainActor public struct CompanionSettingsToolbarItem: ToolbarContent {
    @ObservedObject private var visibility = CompanionAppVisibility.shared
    private let spacing: SpacerSizing
    public init(spacing: SpacerSizing = .fixed) { self.spacing = spacing }

    public var body: some ToolbarContent {
        if !visibility.showInDock && !visibility.showMenuBar {
            ToolbarSpacer(spacing, placement: .primaryAction)
            ToolbarItem(id: "companion-settings", placement: .primaryAction) { CompanionSettingsButton() }
        }
    }
}

private struct CompanionSettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("App Settings", systemImage: "gearshape", action: { openSettings() })
            .help("App Settings")
    }
}
