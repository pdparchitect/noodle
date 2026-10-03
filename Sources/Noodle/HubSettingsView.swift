import AppKit
import AVFoundation
import HubCore
import HubLink
import NoodleHubClient
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

    var body: some View {
        let thisMac = store.thisMac
        Toggle(isOn: Binding(get: { thisMac.isOn }, set: { on in Task { await thisMac.setOn(on) } })) {
            Text("Let My Devices Reach This Mac")
            Text("Your phone and other Macs talk to the bots here as they would a Noodle Hub’s. The Mac stays awake while this is on.")
        }
        if let hub = thisMac.hub {
            HubLinkRows(link: hub.link)
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
            Button("Remove") { removing = device }
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
    @State private var showingArchived = false
    @State private var showingUsers = false

    private var mirror: HubMirror? { store.hubMirrors.first { $0.pairing === pairing } }

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
                if let key = pairing.hub?.key {
                    Text("Hub key \(key.fingerprint)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline) {
                    details
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if pairing.status?.isAdmin == true {
                        Button("Users") { showingUsers = true }
                            .buttonStyle(.link)
                    }
                    if let mirror, case let archived = store.archivedConversations(on: mirror), !archived.isEmpty {
                        Button("Archived (\(archived.count))") { showingArchived = true }
                            .buttonStyle(.link)
                    }
                    Button("Leave") { confirmingLeave = true }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingArchived) {
            if let mirror { HubArchivedSheet(hubName: pairing.hub?.name ?? "Noodle Hub", mirror: mirror).environment(store) }
        }
        .sheet(isPresented: $showingUsers) {
            HubUsersSheet(hubName: pairing.hub?.name ?? "Noodle Hub", pairing: pairing, mirror: mirror)
        }
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

/// One joined Hub's archived bots and groups, each with Unarchive, as in Noodle Mobile.
private struct HubArchivedSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let hubName: String
    let mirror: HubMirror

    var body: some View {
        let archived = store.archivedConversations(on: mirror)
        VStack(spacing: 0) {
            HStack {
                Text("Archived on \(hubName)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Form {
                if archived.isEmpty {
                    Text("Nothing archived").foregroundStyle(.secondary)
                }
                ForEach(archived) { conversation in
                    HStack(spacing: 12) {
                        ConversationAvatar(participants: store.shownParticipants(for: conversation),
                                           isGroup: conversation.kind == .group, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.title(for: conversation))
                            Text(conversation.kind == .group ? "Group" : "Bot").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unarchive") { store.unarchive(conversation) }
                            .buttonStyle(.link)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420, height: 360)
    }
}

/// A Hub's users, for an admin there: those who are not admins can be changed as on the Hub itself.
private struct HubUsersSheet: View {
    @Environment(\.dismiss) private var dismiss
    let hubName: String
    let mirror: HubMirror?
    @State private var users: HubUsers
    @State private var naming: Naming?
    @State private var name = ""
    @State private var removing: LinkUser?
    @State private var removingDevice: LinkUserDevice?
    @State private var inviting: LinkInvitation?

    /// Adding someone, or renaming them.
    private enum Naming {
        case add
        case rename(LinkUser)
    }

    init(hubName: String, pairing: HubPairing, mirror: HubMirror?) {
        self.hubName = hubName
        self.mirror = mirror
        _users = State(initialValue: HubUsers(pairing: pairing))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Users on \(hubName)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Form {
                if !users.isLoaded {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(users.users) { user in
                    userRow(user)
                    ForEach(user.devices) { device in deviceRow(device, of: user) }
                }
                if let error = users.error {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Add User…") {
                    name = ""
                    naming = .add
                }
                .disabled(!users.isLoaded)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
        // Loads when opened, and again whenever the Hub says its users changed.
        .task(id: mirror?.usersChanges) { await users.load() }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button(namingButton) { save(naming) }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Remove \(removing?.name ?? "User")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { user in
            Button("Remove", role: .destructive) { Task { await users.remove(user) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { user in
            Text("“\(user.name)”, their devices and their bots are removed from \(hubName).")
        }
        .alert("Remove \(removingDevice?.name ?? "Device")?", isPresented: Binding(get: { removingDevice != nil }, set: { if !$0 { removingDevice = nil } }),
               presenting: removingDevice) { device in
            Button("Remove", role: .destructive) { Task { await users.remove(device) } }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { device in
            Text("“\(device.name)” can no longer reach \(hubName) until it joins again.")
        }
        .sheet(isPresented: Binding(get: { inviting != nil }, set: { if !$0 { inviting = nil } })) {
            if let inviting { HubInvitationSheet(access: nil, user: nil, invitation: inviting) }
        }
    }

    private var namingTitle: String {
        if case .rename = naming { "Rename User" } else { "New User" }
    }

    private var namingButton: String {
        if case .rename = naming { "Rename" } else { "Add" }
    }

    private func save(_ naming: Naming?) {
        let name = name
        Task {
            switch naming {
            case .add: _ = await users.add(named: name)
            case .rename(let user): await users.rename(user, to: name)
            case nil: break
            }
        }
    }

    private func userRow(_ user: LinkUser) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).lineLimit(1)
                let plan = users.planName(of: user) ?? ""
                Text(user.isAdmin ? "\(plan) · Admin" : plan).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // Admins are managed on the Hub itself, so their rows only show them.
            if !user.isAdmin {
                Button("Invite") { Task { inviting = await users.invite(user) } }
                    .buttonStyle(.link)
                Menu {
                    Picker("Plan", selection: Binding(
                        get: { user.plan },
                        set: { plan in Task { await users.move(user, to: plan) } }
                    )) {
                        ForEach(users.plans) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    Divider()
                    Toggle("Can Pair Devices", isOn: Binding(
                        get: { user.canPairDevices },
                        set: { on in Task { await users.setCanPairDevices(on, for: user) } }
                    ))
                    Divider()
                    Button("Rename…") {
                        name = user.name
                        naming = .rename(user)
                    }
                    Button("Remove", role: .destructive) { removing = user }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("User Actions")
            }
        }
    }

    private func deviceRow(_ device: LinkUserDevice, of user: LinkUser) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                Group {
                    if device.isConnected {
                        Text("Connected")
                    } else if let lastSeen = device.lastSeen {
                        Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                    } else {
                        Text("Paired \(device.paired, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !user.isAdmin {
                Button("Remove") { removingDevice = device }
                    .buttonStyle(.link)
            }
        }
        .padding(.leading, 32)
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
                if let parsed = try? LinkInvitation(text: invitation) {
                    Text("Hub key \(parsed.hubKey.fingerprint)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
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

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let found: @MainActor (String) -> Void
        private let failed: @MainActor (String) -> Void
        private let frames = DispatchQueue(label: "com.pdparchitect.noodle.qr-camera")
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
                // Mac cameras offer no QR metadata, so frames are read like a chosen picture.
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(output) else {
                    failed("The camera cannot read QR codes.")
                    return
                }
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: frames)
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

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard !reported, let frame = sampleBuffer.imageBuffer,
                  let invitation = try? LinkInvitation(frame: frame) else { return }
            reported = true
            stop()
            let text = invitation.url().absoluteString
            let found = found
            DispatchQueue.main.async { MainActor.assumeIsolated { found(text) } }
        }
    }
}
