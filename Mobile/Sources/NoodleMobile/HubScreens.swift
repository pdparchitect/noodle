import HubLink
import PhotosUI
import SwiftUI
import VisionKit

/// The first screen: takes an invitation from the camera, the clipboard or a photo of its QR code.
struct JoinView: View {
    @Environment(HubMemberships.self) private var hubs
    @State private var choosing = false
    /// What was picked in the sheet; it starts once the sheet has gone, so two sheets never overlap.
    @State private var chosen: PairingSource?
    @State private var scanning = false
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("Symbol")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityLabel("Noodle")
            Spacer()
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
        .padding(24)
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
        case .clipboard: paste()
        case .photo: pickingPhoto = true
        case nil: break
        }
        chosen = nil
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            problem = "The clipboard holds no invitation."
            return
        }
        join(text)
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

enum PairingSource { case camera, clipboard, photo }

/// The ways to hand over an invitation, in a short sheet from the bottom.
struct PairingSources: View {
    let choose: (PairingSource) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Pair with Noodle Hub").font(.headline).padding(.bottom, 4)
            // The simulator has no camera; paste the link or choose a picture of the QR code there.
            if DataScannerViewController.isSupported {
                option("Scan QR Code", systemImage: "qrcode.viewfinder", .camera).buttonStyle(.borderedProminent)
            }
            option("Paste Link", systemImage: "doc.on.clipboard", .clipboard).buttonStyle(.bordered)
            option("Choose Photo", systemImage: "photo", .photo).buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(24)
        .presentationDetents([.height(DataScannerViewController.isSupported ? 280 : 220)])
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, systemImage: String, _ source: PairingSource) -> some View {
        Button { choose(source) } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
    }
}

/// Who this phone joined the Hub as, and whether the Hub answers.
struct ProfileView: View {
    @Environment(HubMemberships.self) private var hubs
    let pairing: HubPairing
    @State private var leaving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 72))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(userName).font(.title2.bold())
                        Text(hubName).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    LabeledContent("Status") { status }
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
            .navigationTitle("Profile")
            .refreshable { await pairing.refresh() }
            .confirmationDialog("Leave \(hubName)?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { hubs.leave(pairing) }
            } message: {
                Text("Joining again needs a new invitation.")
            }
        }
    }

    private var hubName: String { pairing.status?.hubName ?? pairing.hub?.name ?? "Noodle Hub" }

    private var userName: String {
        let name = pairing.status?.userName ?? pairing.hub?.userName ?? ""
        return name.isEmpty ? hubName : name
    }

    @ViewBuilder private var status: some View {
        if pairing.isWorking || (pairing.status == nil && pairing.error == nil) {
            Label("Connecting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        } else if pairing.error != nil {
            Label("Not connected", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else {
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
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
