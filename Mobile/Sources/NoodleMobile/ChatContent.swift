import HubLink
import ImageIO
@preconcurrency import LinkPresentation
import PhotosUI
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// One file in a message: a picture shown inline, anything else as a card. Tapping opens Quick Look.
struct AttachmentView: View {
    let chats: HubChats
    let agent: LinkBot
    let attachment: LinkAttachment
    @Environment(\.displayScale) private var displayScale
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var previewing: URL?

    private var isImage: Bool { attachment.mediaType.hasPrefix("image/") }

    var body: some View {
        Button { previewing = url } label: {
            if isImage { picture } else { card }
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .quickLookPreview($previewing)
        .contextMenu {
            if let url { ShareLink(item: url) }
        }
        .task(id: attachment.id) { await load() }
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 240, height: 160)
                .overlay { status }
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle" : Self.symbol(for: attachment.mediaType))
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(Int64(attachment.byteCount), format: .byteCount(style: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 260)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var status: some View {
        if failed {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }

    private func load() async {
        do {
            let file = try await chats.file(for: attachment, in: agent)
            url = file
            image = isImage ? Self.downsampled(file, to: 720) : await thumbnail(of: file)
        } catch {
            failed = true
        }
    }

    private func thumbnail(of file: URL) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 88, height: 88), scale: displayScale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }

    /// Decodes only as many pixels as the bubble shows.
    static func downsampled(_ file: URL, to pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func symbol(for mediaType: String) -> String {
        if mediaType.hasPrefix("image/") { return "photo" }
        if mediaType.hasPrefix("video/") { return "film" }
        if mediaType.hasPrefix("audio/") { return "waveform" }
        if mediaType == "application/pdf" { return "doc.richtext" }
        if mediaType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

/// The preview card for the first public web link in a message, as on the Mac.
enum LinkPreview {
    static func firstURL(in text: String) -> URL? {
        let markdown = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))?
            .runs.compactMap(\.link) ?? []
        let detected = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        return (markdown + detected).first(where: isPublicWeb)
    }

    /// http or https to a named host, never this network: previews fetch the page from the phone.
    static func isPublicWeb(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(), host.contains("."), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost") else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (169, 254), (192, 168), (0, _): return false
        case (172, let second): return !(16...31).contains(second)
        default: return true
        }
    }
}

/// Fetches each link's preview once per launch, failures included.
@MainActor final class LinkMetadataCache {
    static let shared = LinkMetadataCache()
    private var results: [URL: LPLinkMetadata?] = [:]
    private var pending: [URL: Task<LPLinkMetadata?, Never>] = [:]

    func metadata(for url: URL) async -> LPLinkMetadata? {
        if let result = results[url] { return result }
        let task = pending[url] ?? Task {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            return try? await provider.startFetchingMetadata(for: url)
        }
        pending[url] = task
        let result = await task.value
        results[url] = result
        pending[url] = nil
        return result
    }
}

struct LinkPreviewCard: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?

    var body: some View {
        Group {
            if let metadata { LinkPresentationView(metadata: metadata).frame(maxWidth: 280) }
        }
        .task(id: url) { metadata = await LinkMetadataCache.shared.metadata(for: url) }
    }
}

private struct LinkPresentationView: UIViewRepresentable {
    let metadata: LPLinkMetadata

    func makeUIView(context: Context) -> LPLinkView { LPLinkView(metadata: metadata) }

    func updateUIView(_ view: LPLinkView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LPLinkView, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? 280, height: .greatestFiniteMagnitude))
    }
}

/// A file picked for the next message, with a button to take it back out.
struct PendingFileChip: View {
    let file: OutgoingFile
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if file.mediaType.hasPrefix("image/"), let image = AttachmentView.downsampled(file.url, to: 96) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: AttachmentView.symbol(for: file.mediaType)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(file.filename).font(.caption).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(file.filename)")
        }
        .padding(6)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

/// Copies picked files where they stay readable until sent.
enum PickedFiles {
    static func store(_ data: Data, named filename: String, type: UTType?) throws -> OutgoingFile {
        let url = try folder().appendingPathComponent(filename)
        try data.write(to: url)
        return OutgoingFile(url: url, filename: filename, mediaType: type?.preferredMIMEType ?? "application/octet-stream")
    }

    /// A file from the Files app, which is readable only while its access is held.
    static func copy(_ source: URL) throws -> OutgoingFile {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let url = try folder().appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return OutgoingFile(url: url, filename: source.lastPathComponent,
                            mediaType: UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
    }

    static func photo(_ item: PhotosPickerItem, number: Int) async throws -> OutgoingFile? {
        guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        let kind = type?.conforms(to: .movie) == true ? "Video" : "Photo"
        return try store(data, named: "\(kind) \(number).\(type?.preferredFilenameExtension ?? "jpg")", type: type)
    }

    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Outgoing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The camera, returning one photo.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    let taken: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(taken: taken) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let taken: (UIImage) -> Void

        init(taken: @escaping (UIImage) -> Void) { self.taken = taken }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { taken(image) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}

/// The message field. A text view rather than a SwiftUI field, so pasting a copied image attaches it,
/// as in Messages. It grows to six lines, then scrolls.
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let pasted: (UIImage) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholder.text = placeholder
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        if view.text != text { view.text = text }
        view.placeholder.isHidden = !text.isEmpty
        view.pasted = pasted
        context.coordinator.text = $text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let limit = ceil((uiView.font?.lineHeight ?? 22) * 6)
        uiView.isScrollEnabled = fitting > limit
        return CGSize(width: width, height: min(fitting, limit))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            (textView as? PastingTextView)?.placeholder.isHidden = !textView.text.isEmpty
        }
    }
}

/// Offers Paste for copied images too, and hands them over instead of inserting them.
/// A paste the person chooses from the edit menu is always allowed; reading the clipboard
/// from code is not.
final class PastingTextView: UITextView {
    var pasted: ((UIImage) -> Void)?
    let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used from a storyboard.") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if UIPasteboard.general.hasImages, let images = UIPasteboard.general.images, !images.isEmpty {
            images.forEach { pasted?($0) }
        } else {
            super.paste(sender)
        }
    }
}
