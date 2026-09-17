import AppKit
import ServiceManagement
import LocalMacCore

private let identity: LocalMacIdentity = {
    guard let value = LocalMacIdentity.setup(Bundle.main.bundleIdentifier) else { exit(1) }
    return value
}()

private func registrationStatus() -> LocalMacRegistrationStatus {
    let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
    let plist = contents.appendingPathComponent("Library/LaunchDaemons/" + identity.daemonPlist)
    let executable = contents.appendingPathComponent("Library/LaunchServices/LocalMacService")
    guard FileManager.default.isReadableFile(atPath: plist.path),
          FileManager.default.isExecutableFile(atPath: executable.path) else { return .helperMissing }
    switch SMAppService.daemon(plistName: identity.daemonPlist).status {
    // ServiceManagement also returns notFound before it has ever seen a service.
    // The bundled files above distinguish first use from an incomplete app.
    // https://developer.apple.com/forums/thread/719862
    case .notRegistered, .notFound: return .notRegistered
    case .requiresApproval: return .requiresApproval
    case .enabled: return .enabled
    @unknown default: return .unknown
    }
}

// ServiceManagement requires an unsandboxed registrar for an unsandboxed
// daemon. This small setup app registers only its own bundled lifecycle job.
// Its only command is a read-only registration-status query. It accepts no
// account identifiers, credentials, executable paths or maintenance commands.
final class Setup: NSObject, NSApplicationDelegate {
    let service = SMAppService.daemon(plistName: identity.daemonPlist)
    var window: NSWindow!
    var enable: NSButton!
    let status = NSTextField(wrappingLabelWithString: "Enable the account helper once. macOS will ask you to approve it for this Mac.")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 240),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = identity.setupAppName; window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Enable Local Mac")
        title.font = .boldSystemFont(ofSize: 22)
        let detail = NSTextField(wrappingLabelWithString: "The helper creates and starts Noodle’s separate accounts. Stopping a computer retains its account, files and permissions.")
        enable = NSButton(title: "Enable Account Helper…", target: self, action: #selector(register))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        let buttons = NSStackView(views: [enable, done]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, detail, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    func applicationDidBecomeActive(_ notification: Notification) { refresh() }
    func refresh() {
        guard enable != nil else { return }
        let registration = registrationStatus()
        enable.isEnabled = registration != .helperMissing
        enable.title = registration == .enabled || registration == .requiresApproval ? "Open Login Items…" : "Enable Local Mac…"
        if registration == .helperMissing {
            status.stringValue = "The Local Mac helper could not be found. Rebuild or reinstall this Computer app."
        } else if registration == .enabled {
            status.stringValue = "Local Mac is enabled. Return to Computer and choose Start."
        } else if registration == .requiresApproval {
            status.stringValue = "Approve \(identity.setupAppName) in System Settings → General → Login Items & Extensions."
        } else { status.stringValue = "Enable Local Mac to create and start its separate accounts." }
    }
    @objc func register() {
        guard identity.permitsAccountService else {
            status.stringValue = "Test builds cannot register the account service."; return
        }
        do {
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            // The native toggle refreshes stale launch constraints using the
            // installed signed helper. Do not discard the registration here.
            SMAppService.openSystemSettingsLoginItems()
            refresh()
        } catch {
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems(); refresh() }
            else { status.stringValue = error.localizedDescription }
        }
    }
    @objc func finish() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
// Registration repair uses the native Login Items approval flow. Never
// unregister the service automatically during startup or an app update.
if CommandLine.arguments.dropFirst().elementsEqual(["--registration-status"]) {
    print(registrationStatus().rawValue)
    exit(0)
}
guard CommandLine.arguments.count == 1 else {
    fputs("Local Mac Setup does not accept maintenance commands.\n", stderr); exit(1)
}
let application = NSApplication.shared
let setup = Setup()
application.delegate = setup
application.setActivationPolicy(.accessory)
application.run()
