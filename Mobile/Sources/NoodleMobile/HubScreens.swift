import HubLink
import Network
import NoodleBrand
import NoodletRuntime
import PhotosUI
import SwiftUI
import Synchronization
import VisionKit

/// The first screen: takes an invitation from the camera, the clipboard or a photo of its QR code.
struct JoinView: View {
    @Environment(HubMemberships.self) private var hubs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choosing = false
    @State private var problem: String?
    @State private var written = JoinView.wordmarkWritten
    @State private var ready = JoinView.wordmarkWritten

    /// The wordmark is written on once per launch; coming back from the background, or to this
    /// screen after leaving a Hub, shows it whole.
    @MainActor private static var wordmarkWritten = false

    var body: some View {
        ZStack {
            Wordmark(progress: written ? 1 : 0, wordWidth: 220)
                .stroke(.primary, style: StrokeStyle(
                    lineWidth: Wordmark.lineWidth(forWordWidth: 220), lineCap: .round, lineJoin: .round))
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel("Noodle")
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 16) {
                Spacer()
                if let joining = hubs.joining {
                    JoiningProgress(hubName: joining.hubName) { hubs.cancelJoin() }
                } else {
                    if let message = problem ?? hubs.joinError {
                        JoinProblem(message: message, isPairing: problem != nil)
                            .multilineTextAlignment(.center)
                    }
                    Button { choosing = true } label: {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(hubs.isJoining)
                }
            }
            .padding(24)
            .opacity(ready ? 1 : 0)
            .offset(y: ready ? 0 : 12)
        }
        .pairing(isPresented: $choosing, problem: $problem)
        .onAppear {
            guard !written else { return }
            Self.wordmarkWritten = true
            if reduceMotion {
                written = true
                ready = true
            } else {
                // A short pause, the swirl and the word in one stroke, then the button rises in.
                withAnimation(.easeInOut(duration: 3.4).delay(0.55)) { written = true }
                withAnimation(.easeOut(duration: 0.5).delay(4.05)) { ready = true }
            }
        }
    }
}

extension View {
    /// Asks how to hand over an invitation, then joins its Hub.
    func pairing(isPresented: Binding<Bool>, problem: Binding<String?>) -> some View {
        modifier(Pairing(choosing: isPresented, problem: problem))
    }
}

private struct Pairing: ViewModifier {
    @Environment(HubMemberships.self) private var hubs
    @Binding var choosing: Bool
    @Binding var problem: String?
    /// What was picked in the sheet; it starts once the sheet has gone, so two sheets never overlap.
    @State private var chosen: PairingSource?
    @State private var scanning = false
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $choosing, onDismiss: start) {
                PairingSources { source in
                    chosen = source
                    choosing = false
                }
            }
            .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    join(code)
                }
                .ignoresSafeArea()
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { await read(item) }
            }
    }

    private func join(_ text: String) {
        problem = nil
        hubs.clearJoinError()
        Task { await hubs.join(text) }
    }

    private func start() {
        switch chosen {
        case .camera: scanning = true
        case .pasted(let text): join(text)
        case .photo: pickingPhoto = true
        case nil: break
        }
        chosen = nil
    }

    private func read(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)?.cgImage else {
            problem = "The picture could not be read."
            return
        }
        do {
            join(try LinkInvitation(image: image).url().absoluteString)
        } catch {
            problem = error.localizedDescription
        }
    }
}

enum PairingSource { case camera, pasted(String), photo }

/// A join that gets no answer takes a while to give up, so after a moment it says it is still at
/// it, and it can be cancelled.
private let stillTryingAfter: Duration = .seconds(4)

/// The Pair button while joining: which Hub, still trying, and a way out.
private struct JoiningProgress: View {
    let hubName: String
    let cancel: () -> Void
    @State private var slow = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Still trying…").font(.footnote).foregroundStyle(.secondary).opacity(slow ? 1 : 0)
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(hubName)…").lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.fill.tertiary, in: Capsule())
            Button("Cancel", action: cancel)
        }
        .animation(.easeOut, value: slow)
        .task {
            try? await Task.sleep(for: stillTryingAfter)
            slow = true
        }
    }
}

/// Add Hub while joining, in the list of Hubs.
private struct JoiningRow: View {
    let hubName: String
    let cancel: () -> Void
    @State private var slow = false

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            // Two lines from the start, so the row keeps its height when it changes its mind.
            VStack(alignment: .leading, spacing: 2) {
                Text(hubName).lineLimit(1)
                Text(slow ? "Still trying…" : "Connecting…").font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: cancel).buttonStyle(.borderless)
        }
        .animation(.easeOut, value: slow)
        .task {
            try? await Task.sleep(for: stillTryingAfter)
            slow = true
        }
    }
}

/// Why the last join failed. When no address of the Hub answered, it offers to work out why.
private struct JoinProblem: View {
    @Environment(HubMemberships.self) private var hubs
    let message: String
    /// The problem is with the invitation handed over, not with reaching its Hub.
    let isPairing: Bool
    /// Handed to the sheet itself: one that reads it from state can open before the state arrives,
    /// blank. `hubs` forgets it when trying again while the sheet is still going.
    @State private var helping: Unreachable?

    private struct Unreachable: Identifiable {
        let id = UUID()
        let invitation: LinkInvitation
    }

    var body: some View {
        if !isPairing, let unreachable = hubs.unreachableInvitation {
            Text(message).foregroundStyle(.secondary)
            Button {
                helping = Unreachable(invitation: unreachable)
            } label: {
                Text("Help Me Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .sheet(item: $helping) { helping in
                HubTroubleshootingView(invitation: helping.invitation) {
                    hubs.clearJoinError()
                    Task { await hubs.join(helping.invitation.url().absoluteString) }
                }
            }
        } else {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}

/// Tries each way to the Hub, checks this device's connection and says what to try.
struct HubTroubleshootingView: View {
    let invitation: LinkInvitation
    let tryAgain: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var device: HubTroubleshooting.Device?
    /// Whether each address reached the Hub, tried one by one.
    @State private var answers: [LinkEndpoint: Bool]?

    var body: some View {
        NavigationStack {
            List {
                Section("Your Hub") {
                    ForEach(networks, id: \.self) { network in
                        HStack {
                            Text(Self.name(of: network))
                            Spacer(minLength: 8)
                            answer(through: network).font(.subheadline)
                        }
                        // Lines run under the route's name, not under its answer.
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                }
                Section {
                    if let device, let answers {
                        let answered = answers.filter(\.value).map(\.key)
                        ForEach(HubTroubleshooting.advice(for: invitation.endpoints, on: device, answered: answered),
                                id: \.self) { advice in
                            row(advice, on: device)
                        }
                    } else {
                        ProgressView("Checking…").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Help Me Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    tryAgain()
                } label: {
                    Text("Try Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(24)
                .disabled(device == nil || answers == nil)
            }
            .task {
                async let checked = HubTroubleshooting.Device.check(reaching: invitation.endpoints)
                async let tried = probe()
                (device, answers) = await (checked, tried)
            }
        }
    }

    /// The kinds of address the Hub gave, nearest first.
    private var networks: [LinkEndpoint.Network] {
        let present = Set(invitation.endpoints.map(\.network))
        return [LinkEndpoint.Network.home, .tailnet, .internet].filter(present.contains)
    }

    @ViewBuilder private func answer(through network: LinkEndpoint.Network) -> some View {
        if let answers {
            if answers.contains(where: { $0.value && $0.key.network == network }) {
                Label("Answers", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("No answer", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func probe() async -> [LinkEndpoint: Bool] {
        guard let identity = try? invitation.joinIdentity() else { return [:] }
        return await LinkClient.probe(invitation.endpoints, identity: identity, hubKey: invitation.hubKey)
    }

    private static func name(of network: LinkEndpoint.Network) -> String {
        switch network {
        case .home: "Home Wi-Fi"
        case .tailnet: "Tailscale"
        case .internet: "Internet"
        }
    }

    @ViewBuilder private func row(_ advice: HubTroubleshooting.Advice, on device: HubTroubleshooting.Device) -> some View {
        switch advice {
        case .goOnline:
            Label("You're offline. Connect to Wi-Fi or mobile data.", systemImage: "wifi.slash")
        case .allowLocalNetwork:
            VStack(alignment: .leading, spacing: 8) {
                Label("Noodle isn't allowed to look for your Hub on this network. Turn on Local Network for Noodle in Settings.",
                      systemImage: "lock")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .joinSameWiFi:
            Label(device.isOnWiFi
                  ? "Make sure you're on the same Wi-Fi as the Mac your Hub runs on."
                  : "You're on mobile data. Join the same Wi-Fi as the Mac your Hub runs on.",
                  systemImage: "wifi")
        case .connectTailscale:
            Label("Away from that Wi-Fi? Open Tailscale and connect.", systemImage: "point.3.connected.trianglepath.dotted")
        case .tryAgain:
            Label("Your Hub answers now. Tap Try Again.", systemImage: "checkmark.circle")
        case .wakeHubMac:
            Label("Make sure the Mac your Hub runs on is awake and its Hub is open.", systemImage: "desktopcomputer")
        }
    }
}

extension HubTroubleshooting.Device {
    /// What this device can find out about its own connection to the Hub's addresses.
    static func check(reaching endpoints: [LinkEndpoint]) async -> Self {
        let path = await currentPath()
        let isOnline = path.status == .satisfied
        // An address the system answers for itself first, so a name lookup is not what gets refused.
        let homes = endpoints.filter { $0.network == .home }
        let probe = homes.first { !$0.host.hasSuffix(".local") } ?? homes.first
        let isDenied = if isOnline, let probe { await isLocalNetworkDenied(probe) } else { false }
        return Self(isOnline: isOnline, isOnWiFi: path.availableInterfaces.contains { $0.type == .wifi },
                    isOnTailnet: hasTailnetAddress(), isLocalNetworkDenied: isDenied)
    }

    private static let queue = DispatchQueue(label: "HubTroubleshooting")

    private static func currentPath() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = Mutex(false)
            monitor.pathUpdateHandler = { path in
                guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
        }
    }

    /// Sends nothing: the system decides before a UDP flow is ready, and asks the first time.
    private static func isLocalNetworkDenied(_ endpoint: LinkEndpoint) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .udp)
        let answered = Mutex(false)
        return await withCheckedContinuation { continuation in
            @Sendable func answer(_ denied: Bool) {
                guard answered.withLock({ done in defer { done = true }; return !done }) else { return }
                connection.cancel()
                continuation.resume(returning: denied)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: answer(false)
                case .waiting(let error), .failed(let error):
                    answer(connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                           || error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) { answer(false) }
        }
    }

    /// Tailscale's tunnel carries an address in 100.64.0.0/10. Some mobile carriers hand out the
    /// same range, so only tunnels count.
    private static func hasTailnetAddress() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).contains { pointer in
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name).hasPrefix("utun"), entry.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { return false }
            var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { return false }
            return LinkEndpoint(host: String(cString: buffer), port: 0).network == .tailnet
        }
    }
}

/// The ways to hand over an invitation, in a short sheet from the bottom.
struct PairingSources: View {
    let choose: (PairingSource) -> Void
    @State private var link = ""

    var body: some View {
        VStack(spacing: 12) {
            // The simulator has no camera; paste the link or choose a picture of the QR code there.
            if DataScannerViewController.isSupported {
                option("Scan QR Code", systemImage: "qrcode.viewfinder", .camera).buttonStyle(.borderedProminent)
            }
            PasteLinkButton { choose(.pasted($0)) }.frame(height: 50)
            option("Choose Photo", systemImage: "photo", .photo).buttonStyle(.bordered)
            #if targetEnvironment(simulator)
            // The Simulator gets a Mac's clipboard too late for the paste button to light up;
            // pasting into a field always works.
            TextField("Invitation Link", text: $link)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(height: 50)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.join)
                .onSubmit { if !link.isEmpty { choose(.pasted(link)) } }
                .onChange(of: link) { _, text in
                    // A whole invitation pasted at once joins without needing Return.
                    if (try? LinkInvitation(text: text)) != nil { choose(.pasted(text)) }
                }
            #endif
        }
        .controlSize(.large)
        .padding(24)
        .presentationDetents([.height(Self.height)])
        .presentationDragIndicator(.visible)
    }

    private static var height: CGFloat {
        #if targetEnvironment(simulator)
        248
        #else
        DataScannerViewController.isSupported ? 244 : 184
        #endif
    }

    private func option(_ title: String, systemImage: String, _ source: PairingSource) -> some View {
        Button { choose(source) } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
    }
}

/// iOS's own paste control. A paste the person starts is always allowed; reading the clipboard from
/// code is refused without asking, as it is in the simulator.
struct PasteLinkButton: UIViewRepresentable {
    let pasted: (String) -> Void

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .tintColor.withAlphaComponent(0.15)
        configuration.baseForegroundColor = .tintColor
        let control = UIPasteControl(configuration: configuration)
        control.target = context.coordinator
        return control
    }

    func updateUIView(_ control: UIPasteControl, context: Context) {}

    func makeCoordinator() -> Receiver { Receiver(pasted: pasted) }

    final class Receiver: UIResponder {
        private let pasted: (String) -> Void

        init(pasted: @escaping (String) -> Void) {
            self.pasted = pasted
            super.init()
            pasteConfiguration = UIPasteConfiguration(forAccepting: String.self)
        }

        override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return }
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                Task { @MainActor in self.pasted(text) }
            }
        }
    }
}

/// Every Hub this phone joined: tap one to show its bots, or its info button for its details. Shown
/// together, tapping a Hub opens its details.
struct HubsView: View {
    @Environment(HubMemberships.self) private var hubs
    /// Each Hub's bots and groups, for its profile's archived ones.
    var chats: [HubChats] = []
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CurrentHub.key) private var current = ""
    @AppStorage(CurrentHub.togetherKey) private var together = false
    /// The folder of the Hub whose details are open.
    @State private var details: URL?
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                if hubs.hubs.count > 1 {
                    Section { Toggle("Show All Hubs Together", isOn: $together) }
                }
                Section {
                    ForEach(hubs.hubs) { pairing in
                        HStack {
                            Button {
                                if together {
                                    details = pairing.directory
                                } else {
                                    current = CurrentHub.name(of: pairing)
                                    dismiss()
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pairing.hubName).foregroundStyle(.primary)
                                    Text(pairing.userName).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            let connection = HubConnection(pairing)
                            Text(connection.title).font(.subheadline).foregroundStyle(connection.color)
                            if !together, hubs.hubs.count > 1, CurrentHub.pick(hubs.hubs, saved: current) === pairing {
                                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Shown")
                            }
                            Button { details = pairing.directory } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Details")
                        }
                    }
                }
                Section {
                    if let joining = hubs.joining {
                        JoiningRow(hubName: joining.hubName) { hubs.cancelJoin() }
                    } else {
                        if let message = problem ?? hubs.joinError {
                            JoinProblem(message: message, isPairing: problem != nil)
                        }
                        Button {
                            problem = nil
                            hubs.clearJoinError()
                            adding = true
                        } label: {
                            Label("Add Hub", systemImage: "plus")
                        }
                        .disabled(hubs.isJoining)
                    }
                }
            }
            .navigationTitle("Hubs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(item: $details) { folder in
                if let pairing = hubs.hubs.first(where: { $0.directory == folder }) {
                    ProfileView(pairing: pairing, chats: chats.first { $0.pairing === pairing })
                }
            }
            .wordmarkRefreshable { await hubs.refreshAll() }
            .pairing(isPresented: $adding, problem: $problem)
        }
    }
}

/// Who this phone joined a Hub as, and whether the Hub answers.
struct ProfileView: View {
    @Environment(HubMemberships.self) private var hubs
    @Environment(\.dismiss) private var dismiss
    let pairing: HubPairing
    var chats: HubChats? = nil
    @State private var leaving = false
    @State private var pairingDevice = false
    @State private var showingArchived = false
    @State private var editingPicture = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Button { editingPicture = true } label: {
                        PersonAvatar(name: pairing.userName, avatar: pairing.avatar, id: pairing.status?.userID, size: 88)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .font(.system(size: 28))
                                    .background(Color(.systemGroupedBackground), in: Circle())
                            }
                    }
                    .buttonStyle(.plain)
                    // A Hub from before pictures of people cannot keep one.
                    .disabled(pairing.status?.userID == nil)
                    .accessibilityLabel("Edit Picture")
                    Text(pairing.userName).font(.title2.bold())
                    Text(pairing.hubName).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    status
                }
                if let plan = pairing.status?.planName, !plan.isEmpty {
                    LabeledContent("Plan", value: plan)
                }
                if let endpoint = pairing.endpoint {
                    LabeledContent("Address", value: endpoint.description)
                }
                if let key = pairing.hub?.key {
                    LabeledContent("Hub Key", value: key.fingerprint)
                }
                if let fingerprint = pairing.keyFingerprint {
                    LabeledContent("Device Key", value: fingerprint)
                }
            }
            if let error = pairing.error {
                Section { Text(error).foregroundStyle(.orange) }
            }
            if let chats, !chats.archivedThreads.isEmpty {
                Section {
                    Button { showingArchived = true } label: {
                        LabeledContent("Archived", value: "\(chats.archivedThreads.count)")
                            .foregroundStyle(.primary)
                    }
                }
            }
            if pairing.status?.canPairDevices == true {
                Section {
                    Button("Pair Another Device") { pairingDevice = true }
                }
            }
            if pairing.status?.isAdmin == true {
                Section {
                    NavigationLink("Users") { UsersView(pairing: pairing, chats: chats) }
                }
            }
            Section {
                Button("Leave Hub", role: .destructive) { leaving = true }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $pairingDevice) { PairDeviceView(title: "Pair a Device") { try await pairing.invite() } }
        .sheet(isPresented: $editingPicture) { PersonPictureEditor(pairing: pairing) }
        .sheet(isPresented: $showingArchived) { if let chats { ArchivedView(chats: chats) } }
        .wordmarkRefreshable { await pairing.refresh() }
        .confirmationDialog("Leave \(pairing.hubName)?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave", role: .destructive) {
                dismiss()
                hubs.leave(pairing)
            }
        } message: {
            Text("Joining again needs a new invitation.")
        }
    }

    private var status: some View {
        let connection = HubConnection(pairing)
        return Text(connection.title).foregroundStyle(connection.color)
    }
}

/// One Hub's archived bots and groups, each with Unarchive.
struct ArchivedView: View {
    @Environment(\.dismiss) private var dismiss
    let chats: HubChats

    var body: some View {
        NavigationStack {
            List(chats.archivedThreads) { thread in
                HStack(spacing: 12) {
                    // Opens it to read; nothing can be sent until it is unarchived.
                    NavigationLink { ChatView(chats: chats, threadID: thread.id) } label: {
                        HStack(spacing: 12) {
                            ThreadAvatar(chats: chats, thread: thread, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.name)
                                Text(thread.group == nil ? "Bot" : "Group").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Unarchive") {
                        Task {
                            do { try await chats.setArchived(false, thread) }
                            catch { chats.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .overlay {
                if chats.archivedThreads.isEmpty { ContentUnavailableView("Nothing Archived", systemImage: "archivebox") }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// A Hub's users, for an admin there.
struct UsersView: View {
    var chats: HubChats?
    @State private var users: HubUsers
    @State private var adding = false
    @State private var name = ""

    init(pairing: HubPairing, chats: HubChats?) {
        self.chats = chats
        _users = State(initialValue: HubUsers(pairing: pairing))
    }

    var body: some View {
        List {
            if let error = users.error {
                Section { Text(error).foregroundStyle(.orange) }
            }
            Section {
                ForEach(users.users) { user in
                    NavigationLink { UserView(users: users, id: user.id) } label: {
                        HStack(spacing: 12) {
                            PersonAvatar(name: user.name, avatar: user.avatar, id: user.id, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name)
                                let plan = users.planName(of: user) ?? ""
                                Text(user.isAdmin ? "\(plan) · Admin" : plan).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay { if !users.isLoaded { ProgressView() } }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add User", systemImage: "plus") {
                    name = ""
                    adding = true
                }
                .disabled(!users.isLoaded)
            }
        }
        .alert("New User", isPresented: $adding) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let name = name
                Task { _ = await users.add(named: name) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        // Loads when opened, and again whenever the Hub says its users changed.
        .task(id: chats?.usersChanges) { await users.load() }
        .wordmarkRefreshable { await users.load() }
    }
}

/// One of a Hub's users, for an admin there. Admins are shown without anything to change.
struct UserView: View {
    @Environment(\.dismiss) private var dismiss
    let users: HubUsers
    let id: UUID
    @State private var renaming = false
    @State private var name = ""
    @State private var removing = false
    @State private var removingDevice: LinkUserDevice?
    @State private var inviting = false

    var body: some View {
        if let user = users.users.first(where: { $0.id == id }) {
            content(user)
        } else {
            ContentUnavailableView("User Removed", systemImage: "person.slash")
        }
    }

    private func content(_ user: LinkUser) -> some View {
        List {
            if let error = users.error {
                Section { Text(error).foregroundStyle(.orange) }
            }
            Section {
                Picker("Plan", selection: Binding(
                    get: { user.plan },
                    set: { plan in Task { await users.move(user, to: plan) } }
                )) {
                    ForEach(users.plans) { Text($0.name).tag($0.id) }
                }
                Toggle("Can Pair Devices", isOn: Binding(
                    get: { user.canPairDevices },
                    set: { on in Task { await users.setCanPairDevices(on, for: user) } }
                ))
            } footer: {
                if user.isAdmin { Text("Admins are changed only in the Hub’s own Settings.") }
            }
            .disabled(user.isAdmin)
            Section("Devices") {
                ForEach(user.devices) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Group {
                            if device.isConnected {
                                Text("Connected")
                            } else if let lastSeen = device.lastSeen {
                                Text("Last seen \(lastSeen, format: .relative(presentation: .named))")
                            } else {
                                Text("Paired \(device.paired, format: .relative(presentation: .named))")
                            }
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if !user.isAdmin {
                            Button("Remove", role: .destructive) { removingDevice = device }
                        }
                    }
                }
                if user.devices.isEmpty {
                    Text("No devices").foregroundStyle(.secondary)
                }
                if !user.isAdmin {
                    Button("Invite") { inviting = true }
                }
            }
            if !user.isAdmin {
                Section {
                    Button("Remove User", role: .destructive) { removing = true }
                }
            }
        }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !user.isAdmin {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rename") {
                        name = user.name
                        renaming = true
                    }
                }
            }
        }
        .alert("Rename User", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = name
                Task { await users.rename(user, to: name) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Remove \(user.name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await users.remove(user)
                    if users.error == nil { dismiss() }
                }
            }
        } message: {
            Text("Their devices and their bots are removed from the Hub.")
        }
        .confirmationDialog("Remove \(removingDevice?.name ?? "Device")?",
                            isPresented: Binding(get: { removingDevice != nil }, set: { if !$0 { removingDevice = nil } }),
                            titleVisibility: .visible, presenting: removingDevice) { device in
            Button("Remove", role: .destructive) { Task { await users.remove(device) } }
        } message: { _ in
            Text("It can no longer reach the Hub until it joins again.")
        }
        .sheet(isPresented: $inviting) {
            PairDeviceView(title: "Invite \(user.name)") {
                if let invitation = await users.invite(user) { return invitation }
                throw LinkError(users.error ?? "The Hub made no invitation.")
            }
        }
    }
}

/// Whether a Hub answers this launch.
enum HubConnection: Equatable {
    case connecting, connected, notConnected

    /// The status saved at the last launch shows first; only an answer this launch means connected.
    init(isWorking: Bool, answered: Bool, failed: Bool) {
        self = if isWorking || (!answered && !failed) { .connecting } else if failed { .notConnected } else { .connected }
    }

    @MainActor init(_ pairing: HubPairing) {
        self.init(isWorking: pairing.isWorking, answered: pairing.endpoint != nil, failed: pairing.error != nil)
    }

    var title: String {
        switch self {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .notConnected: "Not connected"
        }
    }

    var color: Color {
        switch self {
        case .connecting: .secondary
        case .connected: .green
        case .notConnected: .orange
        }
    }

    /// What a bot's dot shows: the phase it last reported is stale once its Hub stops answering.
    func phase(of phase: LinkBotPhase?) -> LinkBotPhase? { self == .notConnected ? .offline : phase }
}

/// A one-time invitation from the Hub: for another device of this person, or, for an admin, of someone else.
struct PairDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let invite: () async throws -> LinkInvitation
    @State private var invitation: LinkInvitation?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let invitation {
                    let url = invitation.url()
                    if let code = invitation.qrCode() {
                        Image(decorative: code, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 240, height: 240)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Invitation QR Code")
                    }
                    Text("Hub key \(invitation.hubKey.fingerprint)")
                        .font(.footnote.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Link") { UIPasteboard.general.url = url }
                        ShareLink("Share…", item: url)
                    }
                    .buttonStyle(.bordered)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < invitation.expires {
                            Text("Expires \(invitation.expires, format: .relative(presentation: .named))")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("New Invitation") { Task { await load() } }
                        }
                    }
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            invitation = try await invite()
            problem = nil
        } catch {
            invitation = nil
            problem = error.localizedDescription
        }
    }
}

extension HubPairing {
    var hubName: String { status?.hubName ?? hub?.name ?? "Noodle Hub" }

    /// Who this phone joined as.
    var userName: String {
        let name = status?.userName ?? hub?.userName ?? ""
        return name.isEmpty ? hubName : name
    }
}

/// The camera, reporting the first Noodle Hub invitation it sees.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (String) -> Void
        private var reported = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let code) in addedItems {
                guard !reported, let text = code.payloadStringValue, (try? LinkInvitation(text: text)) != nil else { continue }
                reported = true
                found(text)
            }
        }
    }
}

/// Options for the whole app, whichever Hub is shown.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AttachmentLayout.key) private var attachmentLayout = AttachmentLayout.standard.rawValue
    @AppStorage(WebLinkPreview.key) private var previewsLinks = true
    @AppStorage(ScreenControlHaptics.key) private var haptics = false
    @State private var noodlets = NoodletGrants().all

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Attachments", selection: $attachmentLayout) {
                        ForEach(AttachmentLayout.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Attachments")
                } footer: {
                    Text((AttachmentLayout(rawValue: attachmentLayout) ?? .standard).explanation)
                }
                Section {
                    Toggle("Preview Web Links", isOn: $previewsLinks)
                } footer: {
                    Text("Web links open in a preview first, with a button to continue in Safari. When off, they open in Safari.")
                }
                Section {
                    Toggle("Haptics for On-Screen Controls", isOn: $haptics)
                }
                if !noodlets.isEmpty {
                    Section("Noodlet Permissions") {
                        ForEach(noodlets) { grant in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(grant.title)
                                Text(grant.permissions.compactMap { NoodletManifest.permissionTitles[$0] }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onDelete { rows in
                            rows.forEach { NoodletGrants().revoke(noodlets[$0].id) }
                            noodlets = NoodletGrants().all
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
