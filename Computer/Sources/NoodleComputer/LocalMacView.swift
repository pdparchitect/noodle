import AppKit
import ComputerCore
import ComputerEngine
import LocalMacCore
import SwiftUI
import NoodleSettingsUI

struct NewLocalMacView: View {
    @ObservedObject var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("StartNewComputersAutomatically") private var startNewComputersAutomatically = true
    @State private var name = "My Local Mac"
    @State private var appearance = ComputerAppearance()
    @State private var failure: String?
    @State private var registration: LocalMacRegistrationStatus?
    private var creating: Bool { store.creationStatus != nil }
    private var draft: Computer {
        var computer = Computer(name: name, kind: .localMac)
        computer.appearance = appearance
        return computer
    }
    private var canCreate: Bool { !creating && (try? draft.validate()) != nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .foregroundStyle(.blue).disabled(creating)
                Spacer()
                Text("New Local Mac").font(.headline)
                Spacer()
                Button("Create") {
                    Task {
                        let computer = draft
                        if await store.create(computer, source: nil) {
                            dismiss()
                            if startNewComputersAutomatically,
                               let session = store.sessions.first(where: { $0.id == computer.id }) {
                                await store.start(session)
                            }
                        } else {
                            failure = store.creationWasCancelled ? nil : store.error
                            store.error = nil
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!canCreate)
                    .foregroundStyle(canCreate ? Color.blue : .secondary)
            }.buttonStyle(.plain).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ComputerIconButton(appearance: $appearance, symbol: ComputerKind.localMac.symbol)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().lineLimit(1)
                }.padding(12).background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
                Text("A separate account on this Mac, with its own desktop and files. It shares this Mac’s operating system, storage and network.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let registration {
                    HStack {
                        Label(registration.setupTitle, systemImage: registration == .enabled ? "checkmark.circle" : "lock.shield")
                            .foregroundStyle(registration == .enabled ? Color.secondary : .orange)
                        Spacer()
                        if registration != .enabled {
                            Button(registration.setupActionTitle) {
                                do { try LocalMacSetup.resolve(registration) } catch { failure = error.localizedDescription }
                            }
                        }
                    }.font(.callout)
                } else { ProgressView("Checking Local Mac setup…").controlSize(.small) }
                ComputerAppearanceRow(appearance: $appearance)
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }.padding(20).disabled(creating)
        }.frame(width: 520).noodleSheetSizing()
            .interactiveDismissDisabled(creating)
            .task { registration = await LocalMacSetup.registrationStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { registration = await LocalMacSetup.registrationStatus() }
            }
    }
}

struct LocalMacDesktopView: View {
    @ObservedObject var runtime: LocalMacComputer
    var active = true
    var openSettings: () -> Void
    private var issue: (message: String, settings: Bool, dismissible: Bool)? {
        if let status = runtime.status {
            if !status.screenCapture { return ("Screen Recording access is required to show this desktop.", true, false) }
            if !status.accessibility { return ("\(LocalMacSetup.controlPermissionName) is required for mouse and keyboard control.", true, false) }
            if !status.postEvents { return ("Restart this computer to enable mouse and keyboard control.", false, false) }
            if status.setupRunning { return ("Restart this computer to finish account setup.", false, false) }
            if let detail = status.detail { return (detail, false, false) }
        }
        return runtime.error.map { ($0, false, true) }
    }
    var body: some View {
        VStack(spacing: 0) {
            LocalMacSurface(runtime: runtime, active: active).background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if runtime.image == nil {
                        if let issue {
                            VStack(spacing: 12) {
                                Text(issue.message).multilineTextAlignment(.center)
                                if issue.settings { Button("Settings…", action: openSettings) }
                                else if runtime.canRetryCapture { Button("Try Again") { Task { await runtime.retryCapture() } } }
                            }.padding(24)
                        } else { ProgressView("Waiting for desktop…").allowsHitTesting(false) }
                    }
                }
            if runtime.image != nil, let issue {
                HStack {
                    Text(issue.message).font(.caption).textSelection(.enabled)
                    Spacer()
                    if issue.settings { Button("Settings…", action: openSettings) }
                    else if issue.dismissible { Button("Dismiss") { runtime.error = nil } }
                }.padding(8)
            }
        }
        .task {
            while !Task.isCancelled {
                await runtime.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// Recovery instructions live in the existing computer settings, not above and
/// below the desktop at the same time. Only offer the permission still missing.
struct LocalMacPermissionsSettings: View {
    @ObservedObject var runtime: LocalMacComputer
    @State private var preparing = false
    @State private var failure: String?
    var body: some View {
        if let status = runtime.status, !status.screenCapture || !status.accessibility {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allow \(!status.screenCapture ? "Screen Recording" : LocalMacSetup.controlPermissionName) for \(LocalMacSetup.desktopName).")
                Text("Add the helper shown in Finder using + in System Settings, then enable it. Restart this computer after granting access.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") {
                        showHelper(pane: !status.screenCapture ? "Privacy_ScreenCapture" : "Privacy_Accessibility")
                    }.disabled(preparing)
                    Button("Show Desktop Helper") { showHelper() }.disabled(preparing)
                }
                if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            }
        }
    }
    private func showHelper(pane: String? = nil) {
        preparing = true; failure = nil
        Task {
            defer { preparing = false }
            do {
                let helper = try LocalMacSetup.desktopForPermissions()
                NSWorkspace.shared.activateFileViewerSelecting([helper])
                if let pane { openPrivacy(pane) }
            } catch { failure = error.localizedDescription }
        }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}
