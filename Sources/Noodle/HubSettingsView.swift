import AppKit
import AVFoundation
import HubCore
import HubLink
import NoodleRuntimeSettings
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Hub: this Mac serving its owner's devices, and the Noodle Hubs it joined.
struct HubSettingsView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        Form {
            Section("This Mac") { ThisMacRows() }
            Section("Noodle Hubs") { JoinedHubRows() }
        }
        .formStyle(.grouped)
    }
}

/// Whether the owner's phone and other Macs can reach this Mac, and which have joined.
private struct ThisMacRows: View {
    @Environment(NoodleStore.self) private var store
    @State private var inviting: LinkInvitation?
    @State private var removing: HubDevice?
    @State private var editingAddress = false
    @State private var address = ""

    var body: some View {
        let thisMac = store.thisMac
        Toggle(isOn: Binding(get: { thisMac.isOn }, set: { on in Task { await thisMac.setOn(on) } })) {
            Text("Let My Devices Reach This Mac")
            Text("Your phone and other Macs talk to the bots here as they would a Noodle Hub’s. The Mac stays awake while this is on.")
        }
        if let hub = thisMac.hub {
            status(hub.link)
            network(hub.link)
            ForEach(hub.access.devices) { device in deviceRow(device, hub: hub) }
            HStack {
                Spacer()
                Button("Add Device…") { inviting = hub.link.invite(hub.owner) }
                    .disabled(hub.link.state == .stopped || hub.link.state == .starting)
            }
            .sheet(isPresented: Binding(get: { inviting != nil }, set: { if !$0 { inviting = nil } })) {
                if let inviting { HubInvitationSheet(access: hub.access, user: hub.owner, invitation: inviting, title: "Add a Device") }
            }
            .alert("Remove \(removing?.name ?? "Device")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                   presenting: removing) { device in
                Button("Remove", role: .destructive) { hub.access.remove(device) }
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            } message: { device in
                Text("“\(device.name)” can no longer reach this Mac until it joins again.")
            }
        }
    }

    @ViewBuilder private func status(_ link: HubLinkService) -> some View {
        switch link.state {
        case .listening:
            if case .open = link.router {
                SettingsStatusLabel(title: "Reachable from anywhere", systemImage: "checkmark.circle.fill", color: .green)
            } else if link.manualEndpoint != nil {
                SettingsStatusLabel(title: "Reachable through your address", systemImage: "checkmark.circle.fill", color: .green)
            } else {
                SettingsStatusLabel(title: "Reachable on this network", systemImage: "checkmark.circle.fill", color: .green)
            }
        case .failed(let reason):
            SettingsStatusLabel(title: reason, systemImage: "exclamationmark.circle.fill", color: .orange)
        case .starting, .stopped:
            SettingsStatusLabel(title: "Starting…", systemImage: "circle.dotted", color: .secondary)
        }
    }

    /// Reaching this Mac away from home, as with a Noodle Hub: the router forwards its port, or an
    /// address the owner set up reaches it.
    @ViewBuilder private func network(_ link: HubLinkService) -> some View {
        Toggle("Open Port on Router", isOn: Binding(get: { link.opensRouterPort }, set: { link.opensRouterPort = $0 }))
            .help("Asks the router, through UPnP or NAT-PMP, to forward this Mac’s port so your devices reach it away from home")
        LabeledContent("Addresses") {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(link.endpoints, id: \.self) { Text($0.description).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        HStack {
            Spacer()
            Button(link.manualEndpoint == nil ? "Add Remote Address…" : "Change Remote Address…") {
                address = link.manualAddress
                editingAddress = true
            }
        }
        .alert("Remote Address", isPresented: $editingAddress) {
            TextField("Address", text: $address, prompt: Text("mac.example.com"))
            Button("Cancel", role: .cancel) {}
            Button("Save") { link.manualAddress = address.trimmingCharacters(in: .whitespaces) }
        } message: {
            Text("A domain, public address or forwarded port that reaches this Mac from outside your network. Leave it empty to remove it.")
        }
    }

    private func deviceRow(_ device: HubDevice, hub: PersonalHub) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    if hub.link.isConnected(device) {
                        Text("Connected")
                    } else if let lastSeen = device.lastSeen {
                        Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                    } else {
                        Text("Joined \(device.paired, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Remove…") { removing = device }
        }
    }
}

/// Each Noodle Hub this Mac joined, then a row to join another.
private struct JoinedHubRows: View {
    @Environment(NoodleStore.self) private var store
    @State private var joining = false

    var body: some View {
        Group {
            ForEach(store.hubs.hubs) { pairing in
                HubRow(pairing: pairing)
            }
            joinRow
        }
        .onAppear { if store.pendingHubInvitation != nil { joining = true } }
        .onChange(of: store.pendingHubInvitation) { _, invitation in if invitation != nil { joining = true } }
        .sheet(isPresented: $joining) { HubJoinSheet().environment(store) }
    }

    private var joinRow: some View {
        HStack(alignment: .top, spacing: 12) {
            HubIcon()
            VStack(alignment: .leading, spacing: 6) {
                Text("Noodle Hub").fontWeight(.semibold)
                HStack(alignment: .firstTextBaseline) {
                    Text("Use the harnesses a Noodle Hub lends you, such as a friend’s or one of your own Macs.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Join") {
                        store.hubs.clearJoinError()
                        joining = true
                    }
                    .buttonStyle(.link)
                    .help("Join a Noodle Hub with an invitation")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HubIcon: View {
    var body: some View {
        Image(systemName: "server.rack")
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

/// One joined Hub: whether it answers, and what it lends.
private struct HubRow: View {
    @Environment(NoodleStore.self) private var store
    let pairing: HubPairing
    @State private var confirmingLeave = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HubIcon()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(pairing.hub?.name ?? "Noodle Hub").fontWeight(.semibold)
                    Spacer()
                    status
                }
                Text("Noodle Hub · \(pairing.status?.userName ?? pairing.hub?.userName ?? "")"
                     + (pairing.status.map { " · \($0.planName) plan" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(alignment: .firstTextBaseline) {
                    details
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Leave") { confirmingLeave = true }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: pairing.hub?.key) { await pairing.refresh() }
        .alert("Leave \(pairing.hub?.name ?? "Hub")?", isPresented: $confirmingLeave) {
            Button("Leave", role: .destructive) { store.leaveHub(pairing) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("Its bots stay on the Hub for your other devices. Joining again needs a new invitation.")
        }
    }

    @ViewBuilder private var status: some View {
        if pairing.isWorking {
            SettingsStatusLabel(title: "Connecting…", systemImage: "circle.dotted", color: .secondary)
        } else if pairing.error != nil {
            SettingsStatusLabel(title: "Not connected", systemImage: "exclamationmark.circle.fill", color: .orange)
        } else {
            SettingsStatusLabel(title: "Connected", systemImage: "checkmark.circle.fill", color: .green)
                .help(pairing.endpoint.map { "Connected via \($0.description)" } ?? "")
        }
    }

    @ViewBuilder private var details: some View {
        if let error = pairing.error {
            Text(error).foregroundStyle(.orange).textSelection(.enabled)
        } else if let status = pairing.status {
            Text(status.harnesses.isEmpty ? "Your plan lends no harnesses"
                 : "Lends " + status.harnesses.map { harness in
                     harness.profileName.map { "\(harness.providerName) (\($0))" } ?? harness.providerName
                 }.joined(separator: ", "))
        }
    }
}

/// Takes an invitation typed or pasted as a link, or read from a picture or the camera.
struct HubJoinSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var invitation = ""
    @State private var scanning = false
    @State private var problem: String?
    @State private var dropTargeted = false

    private var hubs: HubMemberships { store.hubs }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Join Noodle Hub").font(.title2.bold())
                TextField("Invitation", text: $invitation, prompt: Text("noodle://join-hub?…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(join)
                HStack {
                    Button("Paste", action: paste)
                    Button("Choose Image…", action: chooseImage)
                    Button(scanning ? "Stop Camera" : "Scan with Camera") { scanning.toggle() }
                    Spacer()
                }
                if scanning {
                    QRCameraView { code in
                        scanning = false
                        invitation = code
                        join()
                    } failed: { message in
                        scanning = false
                        problem = message
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let message = problem ?? hubs.joinError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            Divider()
            HStack {
                if hubs.isJoining { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Join", action: join)
                    .keyboardShortcut(.defaultAction)
                    .disabled(hubs.isJoining || invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted, perform: drop)
        .onAppear {
            if let pending = store.pendingHubInvitation {
                store.pendingHubInvitation = nil
                invitation = pending
            }
        }
    }

    private func join() {
        let text = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !hubs.isJoining else { return }
        problem = nil
        Task {
            await store.joinHub(text)
            if hubs.joinError == nil { dismiss() }
        }
    }

    /// A copied link, or a copied picture of the QR code.
    private func paste() {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            invitation = text
            join()
        } else if let image = NSImage(pasteboard: pasteboard) {
            read(image)
        } else {
            problem = "The clipboard holds no invitation."
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        read(image)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else { return }
                Task { @MainActor in read(image) }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let image = NSImage(contentsOf: url) else { return }
            Task { @MainActor in read(image) }
        }
        return true
    }

    private func read(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            problem = "The picture could not be read."
            return
        }
        do {
            invitation = try LinkInvitation(image: cgImage).url().absoluteString
            join()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The Mac's camera, reporting the first QR code it sees.
private struct QRCameraView: NSViewRepresentable {
    let found: @MainActor (String) -> Void
    let failed: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found, failed: failed) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let found: @MainActor (String) -> Void
        private let failed: @MainActor (String) -> Void
        private var reported = false

        init(found: @escaping @MainActor (String) -> Void, failed: @escaping @MainActor (String) -> Void) {
            self.found = found
            self.failed = failed
        }

        @MainActor func start(in view: NSView) {
            Task { @MainActor in
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    failed("Allow Noodle to use the camera in System Settings > Privacy & Security > Camera.")
                    return
                }
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                    failed("No camera is available.")
                    return
                }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    failed("The camera cannot read QR codes.")
                    return
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = view.bounds
                preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                view.layer?.addSublayer(preview)
                let session = session
                DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
            }
        }

        func stop() {
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !reported else { return }
            for case let code as AVMetadataMachineReadableCodeObject in objects {
                guard let text = code.stringValue, (try? LinkInvitation(text: text)) != nil else { continue }
                reported = true
                stop()
                MainActor.assumeIsolated { found(text) }
                return
            }
        }
    }
}
