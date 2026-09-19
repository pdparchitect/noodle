import AppKit
import AVFoundation
import CoreGraphics
import Observation
import SwiftUI
import UserNotifications

/// A macOS privacy permission a Noodle feature depends on.
enum AppPermission: String, CaseIterable, Identifiable {
    case microphone, screenRecording, notifications

    var id: String { rawValue }

    var name: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .notifications: return "Notifications"
        }
    }

    var summary: String {
        switch self {
        case .microphone: return "Record voice messages."
        case .screenRecording: return "Preview and capture screens and windows for a message."
        case .notifications: return "Announce bot replies and show the unread count on the Dock icon."
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .notifications: return "bell.badge"
        }
    }

    /// The System Settings pane where this permission is changed.
    var settingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .notifications:
            let app = Bundle.main.bundleIdentifier.map { "?id=\($0)" } ?? ""
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension\(app)")
        }
    }
}

enum AppPermissionStatus: Equatable {
    case allowed
    /// macOS has not asked yet; requesting shows the system prompt.
    case notRequested
    /// Only System Settings can change it now.
    case denied
}

/// macOS reports Screen Recording only as allowed or not, so Noodle remembers
/// asking to tell a refusal from a permission that was never requested.
enum ScreenRecordingAccess {
    static let requestedDefaultsKey = "screenRecordingAccessRequested"

    static var status: AppPermissionStatus {
        if CGPreflightScreenCaptureAccess() { return .allowed }
        return UserDefaults.standard.bool(forKey: requestedDefaultsKey) ? .denied : .notRequested
    }

    static func request() {
        UserDefaults.standard.set(true, forKey: requestedDefaultsKey)
        CGRequestScreenCaptureAccess()
    }
}

/// Reports which of Noodle's macOS permissions are allowed, as of the last refresh.
@MainActor @Observable final class AppPermissionChecker {
    static let shared = AppPermissionChecker()

    private(set) var statuses: [AppPermission: AppPermissionStatus] = [:]
    @ObservationIgnored private let status: @MainActor (AppPermission) async -> AppPermissionStatus
    @ObservationIgnored private let ask: @MainActor (AppPermission) async -> Void
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(status: (@MainActor (AppPermission) async -> AppPermissionStatus)? = nil,
         ask: (@MainActor (AppPermission) async -> Void)? = nil) {
        self.status = status ?? { await Self.systemStatus(of: $0) }
        self.ask = ask ?? { await Self.askSystem(for: $0) }
    }

    /// Permissions the user refused. One never requested is not counted; its
    /// feature asks on first use.
    var needingAttention: Int { statuses.values.filter { $0 == .denied }.count }

    /// Replaces any refresh still in flight. Await the returned task for the result.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        refreshTask?.cancel()
        let task = Task { @MainActor in
            var found: [AppPermission: AppPermissionStatus] = [:]
            for permission in AppPermission.allCases { found[permission] = await status(permission) }
            guard !Task.isCancelled else { return }
            if found != statuses { statuses = found }
        }
        refreshTask = task
        return task
    }

    func request(_ permission: AppPermission) async {
        await ask(permission)
        await refresh().value
    }

    private static func systemStatus(of permission: AppPermission) async -> AppPermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .allowed
            case .notDetermined: return .notRequested
            default: return .denied
            }
        case .screenRecording:
            return ScreenRecordingAccess.status
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional: return .allowed
            case .notDetermined: return .notRequested
            default: return .denied
            }
        }
    }

    private static func askSystem(for permission: AppPermission) async {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording:
            ScreenRecordingAccess.request()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }
}

struct PermissionsSettingsView: View {
    @State private var requesting: AppPermission?
    private let checker: AppPermissionChecker
    private let openSettings: @MainActor (URL) -> Void

    @MainActor init(checker: AppPermissionChecker? = nil,
                    openSettings: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.checker = checker ?? .shared
        self.openSettings = openSettings
    }

    var body: some View {
        Form {
            Section {
                ForEach(AppPermission.allCases) { permission in
                    permissionRow(permission)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { checker.refresh() }
        // Returning from System Settings is when a permission most likely changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checker.refresh()
        }
    }

    private func permissionRow(_ permission: AppPermission) -> some View {
        let status = checker.statuses[permission]
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(permission.name).fontWeight(.semibold)
                    Spacer()
                    statusLabel(status)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(permission.summary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    action(for: permission, status: status)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func statusLabel(_ status: AppPermissionStatus?) -> some View {
        switch status {
        case .allowed:
            SettingsStatusLabel(title: "Allowed", systemImage: "checkmark.circle.fill", color: .green)
        case .notRequested:
            SettingsStatusLabel(title: "Not requested", systemImage: "questionmark.circle", color: .secondary)
        case .denied:
            SettingsStatusLabel(title: "Not allowed", systemImage: "exclamationmark.triangle.fill", color: .orange)
        case nil:
            SettingsStatusLabel(title: "Checking…", systemImage: "circle.dotted", color: .secondary)
        }
    }

    @ViewBuilder private func action(for permission: AppPermission, status: AppPermissionStatus?) -> some View {
        switch status {
        case .notRequested:
            Button(requesting == permission ? "Requesting…" : "Request") {
                requesting = permission
                Task { @MainActor in
                    await checker.request(permission)
                    requesting = nil
                }
            }
            .disabled(requesting != nil)
            .accessibilityLabel("Request \(permission.name) access")
        case .denied:
            Button("Open System Settings") {
                if let url = permission.settingsURL { openSettings(url) }
            }
            .accessibilityLabel("Open \(permission.name) in System Settings")
            .help(permission == .screenRecording
                  ? "Turn on Noodle under Screen Recording. macOS may ask to reopen Noodle."
                  : "Turn on Noodle under \(permission.name)")
        case .allowed, nil:
            EmptyView()
        }
    }
}
