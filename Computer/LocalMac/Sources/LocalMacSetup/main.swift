import AppKit
import ServiceManagement

// ServiceManagement requires an unsandboxed registrar for an unsandboxed
// daemon. This small setup app registers only its own bundled lifecycle job.
// It accepts no commands, account identifiers, credentials or paths.
final class Setup: NSObject, NSApplicationDelegate {
    let service = SMAppService.daemon(plistName: "com.pdparchitect.noodle.computer.localmac.plist")
    var window: NSWindow!
    var enable: NSButton!
    let status = NSTextField(wrappingLabelWithString: "Enable the account helper once. macOS will ask you to approve it for this Mac.")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 240),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Local Mac Setup"; window.isReleasedWhenClosed = false
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
        enable.title = service.status == .enabled ? "Open Login Items…" : "Enable Account Helper…"
        if service.status == .enabled {
            status.stringValue = "The helper is approved. If Start cannot connect after an update, turn LocalMacSetup off and back on in Login Items, then retry Start. Accounts and files are retained."
        } else if service.status == .requiresApproval {
            status.stringValue = "Approve Local Mac Setup in System Settings → General → Login Items & Extensions."
        } else { status.stringValue = "Enable the account helper. Existing accounts and files are retained." }
    }
    @objc func register() {
        guard Bundle.main.bundleIdentifier == "com.pdparchitect.noodle.computer.localmacsetup" else {
            status.stringValue = "Use the installed production-identity app for account setup."; return
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
guard CommandLine.arguments.count == 1 else {
    fputs("Local Mac Setup does not accept maintenance commands.\n", stderr); exit(1)
}
let application = NSApplication.shared
let setup = Setup()
application.delegate = setup
application.setActivationPolicy(.regular)
application.run()
