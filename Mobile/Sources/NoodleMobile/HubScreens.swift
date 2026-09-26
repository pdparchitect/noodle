import HubLink
import PhotosUI
import SwiftUI
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
        VStack(spacing: 16) {
            Spacer()
            let size = CGSize(width: 220, height: 49)
            Wordmark(progress: written ? 1 : 0)
                .stroke(.primary, style: StrokeStyle(
                    lineWidth: Wordmark.lineWidth(in: CGRect(origin: .zero, size: size)),
                    lineCap: .round, lineJoin: .round))
                .frame(width: size.width, height: size.height)
                .accessibilityElement()
                .accessibilityLabel("Noodle")
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Group {
                if hubs.isJoining {
                    ProgressView("Joining…")
                } else if let message = problem ?? hubs.joinError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button { choosing = true } label: {
                    Text("Pair").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(hubs.isJoining)
            }
            .opacity(ready ? 1 : 0)
            .offset(y: ready ? 0 : 12)
        }
        .padding(24)
        .pairing(isPresented: $choosing, problem: $problem)
        .onAppear {
            guard !written else { return }
            Self.wordmarkWritten = true
            if reduceMotion {
                written = true
                ready = true
            } else {
                // The films' pace: a short pause, 2.1 s of writing, then the button rises in.
                withAnimation(.easeInOut(duration: 2.1).delay(0.55)) { written = true }
                withAnimation(.easeOut(duration: 0.5).delay(2.75)) { ready = true }
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
                    if hubs.isJoining {
                        ProgressView("Joining…")
                    } else if let message = problem ?? hubs.joinError {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
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
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(item: $details) { folder in
                if let pairing = hubs.hubs.first(where: { $0.directory == folder }) {
                    ProfileView(pairing: pairing)
                }
            }
            .refreshable { await hubs.refreshAll() }
            .pairing(isPresented: $adding, problem: $problem)
        }
    }
}

/// Who this phone joined a Hub as, and whether the Hub answers.
struct ProfileView: View {
    @Environment(HubMemberships.self) private var hubs
    @Environment(\.dismiss) private var dismiss
    let pairing: HubPairing
    @State private var leaving = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
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
                if let fingerprint = pairing.keyFingerprint {
                    LabeledContent("Device Key", value: fingerprint)
                }
            }
            if let error = pairing.error {
                Section { Text(error).foregroundStyle(.orange) }
            }
            Section {
                Button("Leave Hub", role: .destructive) { leaving = true }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await pairing.refresh() }
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
        // The status shown may be the one saved at the last launch; only an answer this launch means connected.
        let (title, color): (String, Color) = if pairing.isWorking || (pairing.endpoint == nil && pairing.error == nil) {
            ("Connecting…", .secondary)
        } else if pairing.error != nil {
            ("Not connected", .orange)
        } else {
            ("Connected", .green)
        }
        return Text(title).foregroundStyle(color)
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
