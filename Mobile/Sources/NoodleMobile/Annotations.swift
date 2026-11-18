import HubLink
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Comments on a conversation's files and messages, made as the Mac makes them: a note file that goes
/// with the next message and tells the bot what it refers to. A comment on text quotes it and travels as
/// a text file; one on part of a preview travels as the still it was marked on, the part outlined in orange.
enum AnnotationNotes {
    /// The Mac's notes of text files and marked pictures, which every Noodle reads.
    static let version = 2

    static func note(_ request: AnnotationRequest, comment: String) -> LinkAnnotation {
        LinkAnnotation(version: version, sourceAttachmentID: request.sourceAttachmentID, sourceFilename: request.sourceFilename,
                       sourceMessageID: request.sourceMessageID, quote: request.quote,
                       comment: comment.trimmingCharacters(in: .whitespacesAndNewlines), region: request.region)
    }

    /// As the Mac checks a note that arrives: a comment, a source, and a valid region if it has one.
    static func isValid(_ note: LinkAnnotation) -> Bool {
        let regionValid = note.region.map { region in
            [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite) && region.x >= 0 && region.y >= 0 &&
                region.width > 0 && region.height > 0 && region.x + region.width <= 1.000001 && region.y + region.height <= 1.000001
        } ?? true
        return !note.sourceFilename.isEmpty && !note.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            regionValid
    }

    static func filename(for note: LinkAnnotation) -> String {
        let stem = URL(fileURLWithPath: note.sourceFilename).deletingPathExtension().lastPathComponent
        return "Annotation — \(stem.prefix(160)).\(note.region == nil ? "txt" : "png")"
    }

    static func mediaType(for note: LinkAnnotation) -> String { note.region == nil ? "text/plain" : "image/png" }

    /// The Mac's words for a text note's file, so a bot reads the same whichever device commented.
    static func text(of note: LinkAnnotation) -> String {
        let context = note.quote.map { "Selected text\n\($0)" } ?? (note.region == nil
            ? "This comment refers to the whole attachment." : "The marked preview snapshot follows on the next page.")
        let messageReference = note.sourceMessageID.map { "Source message: \($0.uuidString)\n" } ?? ""
        return "Annotation — \(note.sourceFilename)\n\nComment\n\(note.comment)\n\n\(context)\n\n" +
            "Source attachment: \(note.sourceAttachmentID.uuidString)\n\(messageReference)"
    }

    /// What a comment on a message names as its source, as on the Mac. The message itself does not travel.
    static func messageSource(in conversation: String) -> String {
        let safe = conversation.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "Message — \(safe.prefix(100)).txt"
    }

    /// "Recording.swift · lines 12–15", from the new side's numbers, or the old side's for lines only removed.
    static func linesCaption(_ filename: String, new: [Int], old: [Int] = []) -> String {
        let numbers = new.isEmpty ? old : new
        guard let first = numbers.min(), let last = numbers.max() else { return filename }
        let lines = first == last ? "line \(first)" : "lines \(first)–\(last)"
        return "\(filename) · \(lines)\(new.isEmpty ? " (removed)" : "")"
    }

    /// The lines of `text` that `range` touches, counted from 1.
    static func lines(of range: NSRange, in text: String) -> [Int] {
        let string = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= string.length else { return [] }
        let before = string.substring(to: range.location)
        let first = before.components(separatedBy: "\n").count
        let selected = string.substring(with: range)
        // A selection that ends with its line's break stays on that line.
        let trimmed = selected.hasSuffix("\n") ? String(selected.dropLast()) : selected
        return [first, first + trimmed.components(separatedBy: "\n").count - 1]
    }

    // MARK: Regions

    /// Where a picture of `size` shows when fitted whole into `bounds`, as Quick Look shows one.
    static func fitted(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// A fingertip's square around the touch, for a tap or a drag too small to mark anything, as the Mac does for a click.
    static let tapSquare: CGFloat = 24

    /// The box a drag from `start` to `end` marks, within `bounds`.
    static func selection(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        var rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        if rect.width < 4 || rect.height < 4 {
            rect = CGRect(x: start.x - tapSquare / 2, y: start.y - tapSquare / 2, width: tapSquare, height: tapSquare)
        }
        return rect.intersection(bounds)
    }

    /// A box on screen, top-left origin, as fractions of the picture shown in `image`, from its bottom-left corner.
    static func region(of rect: CGRect, in image: CGRect) -> LinkAnnotation.Region? {
        let box = rect.intersection(image)
        guard !box.isNull, box.width > 0, box.height > 0, image.width > 0, image.height > 0 else { return nil }
        return LinkAnnotation.Region(x: (box.minX - image.minX) / image.width, y: (image.maxY - box.maxY) / image.height,
                                     width: box.width / image.width, height: box.height / image.height)
    }

    /// The part of a picture of `size` pixels to show around a region in the comment sheet, top-left origin:
    /// the region with room around it, so it reads in its place.
    static func focus(on region: LinkAnnotation.Region, in size: CGSize) -> CGRect {
        let box = CGRect(x: region.x * size.width, y: (1 - region.y - region.height) * size.height,
                         width: region.width * size.width, height: region.height * size.height)
        let margin = max(box.width, box.height) * 0.4 + 16
        return box.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: size)).integral
    }

    /// The still with the region outlined, as the Mac marks one: orange, with a dark edge that keeps it
    /// readable on light and busy pictures.
    static func markedPNG(_ image: CGImage, region: LinkAnnotation.Region) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // A bitmap context's origin is its bottom-left corner, as a region's is.
        context.draw(image, in: bounds)
        let marked = CGRect(x: region.x * bounds.width, y: region.y * bounds.height,
                            width: region.width * bounds.width, height: region.height * bounds.height)
        let lineWidth = max(2, bounds.width / 450)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.7))
        context.setLineWidth(lineWidth + 2)
        context.stroke(marked)
        context.setStrokeColor(CGColor(red: 1, green: 0.55, blue: 0, alpha: 1))
        context.setLineWidth(lineWidth)
        context.stroke(marked)
        let data = NSMutableData()
        guard let result = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, result, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// A comment being written, and what it refers to.
struct AnnotationRequest: Identifiable {
    let id = UUID()
    let sourceAttachmentID: UUID
    let sourceFilename: String
    var sourceMessageID: UUID?
    /// The text commented on, as the bot reads it.
    var quote: String?
    /// The quote as it shows above the field, when that differs, as a patch's lines without where they are.
    var shownQuote: String?
    /// Under the quote: where it is from.
    var caption: String?
    var monospaced = false
    var region: LinkAnnotation.Region?
    /// The still with the region outlined, as it is sent.
    var markedPNG: Data?
    var comment = ""
    /// The note waiting above the composer that this changes.
    var draft: UUID?

    /// A comment on a whole file.
    static func attachment(_ attachment: LinkAttachment) -> Self {
        AnnotationRequest(sourceAttachmentID: attachment.id, sourceFilename: attachment.filename)
    }

    /// A comment on a message, quoting what was pressed of it. Its source is the message, as on the Mac.
    static func message(_ message: LinkMessage, quote: String, author: String, in conversation: String) -> Self {
        AnnotationRequest(sourceAttachmentID: UUID(), sourceFilename: AnnotationNotes.messageSource(in: conversation),
                          sourceMessageID: message.id, quote: quote, caption: author)
    }
}

/// How a conversation's comments are written. Nil while its Hub would drop what a note refers to.
struct Annotating {
    /// Opens the comment sheet over the conversation.
    let begin: @MainActor (AnnotationRequest) -> Void
    /// Keeps a comment as a note waiting above the composer.
    let save: @MainActor (AnnotationRequest, String) throws -> Void
}

extension EnvironmentValues {
    @Entry var annotating: Annotating?
}

/// Notes waiting above each conversation's composer, kept on this phone with their files until they
/// go with the next message, as the Mac keeps them.
@MainActor @Observable final class AnnotationDrafts {
    struct Draft: Codable, Equatable, Identifiable {
        let id: UUID
        let filename: String
        let mediaType: String
        var annotation: LinkAnnotation
    }

    private(set) var drafts: [UUID: [Draft]]
    @ObservationIgnored let folder: URL

    init(folder: URL) {
        self.folder = folder
        drafts = (try? JSONDecoder().decode([UUID: [Draft]].self, from: Data(contentsOf: folder.appendingPathComponent("drafts.json")))) ?? [:]
        // Files of notes sent while the app was stopped before it could tidy up.
        let kept = Set(drafts.values.flatMap { $0.map(\.id.uuidString) })
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where item.hasDirectoryPath && !kept.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func drafts(in conversationID: UUID) -> [Draft] { drafts[conversationID] ?? [] }

    func url(of draft: Draft) -> URL { url(id: draft.id, filename: draft.filename) }

    private func url(id: UUID, filename: String) -> URL {
        folder.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(filename)
    }

    /// Adds the note, or changes the comment of the one it edits.
    func save(_ request: AnnotationRequest, comment: String, in conversationID: UUID) throws {
        let note = AnnotationNotes.note(request, comment: comment)
        guard AnnotationNotes.isValid(note) else { throw LinkError("Write a comment first.") }
        if let id = request.draft, let index = drafts[conversationID]?.firstIndex(where: { $0.id == id }) {
            var draft = drafts(in: conversationID)[index]
            draft.annotation = note
            // A marked picture stays as it is; a text note's file says the new comment.
            if note.region == nil { try Data(AnnotationNotes.text(of: note).utf8).write(to: url(of: draft), options: .atomic) }
            drafts[conversationID]?[index] = draft
        } else {
            let content: Data
            if note.region != nil {
                guard let png = request.markedPNG else { throw LinkError("The marked picture is missing.") }
                content = png
            } else {
                content = Data(AnnotationNotes.text(of: note).utf8)
            }
            let draft = Draft(id: UUID(), filename: AnnotationNotes.filename(for: note), mediaType: AnnotationNotes.mediaType(for: note),
                              annotation: note)
            try FileManager.default.createDirectory(at: url(of: draft).deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url(of: draft), options: .atomic)
            drafts[conversationID, default: []].append(draft)
        }
        persist()
    }

    /// The sheet that edits a waiting note's comment.
    func request(editing draft: Draft) -> AnnotationRequest {
        let note = draft.annotation
        return AnnotationRequest(sourceAttachmentID: note.sourceAttachmentID, sourceFilename: note.sourceFilename,
                                 sourceMessageID: note.sourceMessageID, quote: note.quote,
                                 caption: note.sourceMessageID == nil ? note.sourceFilename : nil,
                                 monospaced: note.quote != nil && note.sourceMessageID == nil, region: note.region,
                                 markedPNG: note.region == nil ? nil : try? Data(contentsOf: url(of: draft)),
                                 comment: note.comment, draft: draft.id)
    }

    func remove(_ id: UUID, in conversationID: UUID) {
        guard let draft = drafts(in: conversationID).first(where: { $0.id == id }) else { return }
        drafts[conversationID]?.removeAll { $0.id == id }
        if drafts[conversationID]?.isEmpty == true { drafts[conversationID] = nil }
        try? FileManager.default.removeItem(at: url(of: draft).deletingLastPathComponent())
        persist()
    }

    /// The conversation's notes as files of the message being sent, no longer waiting. Their files stay
    /// until `discard`, once the message has its own copies, or `restore` if it could not be sent.
    func take(in conversationID: UUID) -> [OutgoingFile] {
        let taken = drafts(in: conversationID).map { draft in
            OutgoingFile(id: draft.id, url: url(of: draft), filename: draft.filename, mediaType: draft.mediaType,
                         annotation: draft.annotation)
        }
        guard !taken.isEmpty else { return [] }
        drafts[conversationID] = nil
        persist()
        return taken
    }

    func discard(_ files: [OutgoingFile]) {
        for file in files where file.annotation != nil {
            try? FileManager.default.removeItem(at: url(id: file.id, filename: file.filename).deletingLastPathComponent())
        }
    }

    /// Notes back above the composer: ones that could not be sent, or those of a message taken back to edit.
    func restore(_ files: [OutgoingFile], in conversationID: UUID) {
        let existing = Set(drafts(in: conversationID).map(\.id))
        for file in files where !existing.contains(file.id) {
            guard let annotation = file.annotation else { continue }
            let kept = url(id: file.id, filename: file.filename)
            if kept.standardizedFileURL != file.url.standardizedFileURL {
                try? FileManager.default.removeItem(at: kept.deletingLastPathComponent())
                guard (try? FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                      (try? FileManager.default.copyItem(at: file.url, to: kept)) != nil else { continue }
            }
            drafts[conversationID, default: []].append(Draft(id: file.id, filename: file.filename, mediaType: file.mediaType,
                                                             annotation: annotation))
        }
        persist()
    }

    /// Notes of conversations gone go with them.
    func retain(_ conversations: Set<UUID>) {
        for conversationID in drafts.keys where !conversations.contains(conversationID) {
            for draft in drafts(in: conversationID) { remove(draft.id, in: conversationID) }
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(drafts).write(to: folder.appendingPathComponent("drafts.json"), options: .atomic)
    }
}

// MARK: - Comment sheet

/// Writes a comment on what was picked, typed or dictated, as the Mac's annotation popover does.
struct AnnotationCommentSheet: View {
    let request: AnnotationRequest
    let save: @MainActor (String) throws -> Void
    @State private var comment: String
    @State private var problem: String?
    /// Dictation transcribes on this phone, as voice messages do.
    @State private var dictation: VoiceRecorder
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(request: AnnotationRequest, save: @escaping @MainActor (String) throws -> Void) {
        self.request = request
        self.save = save
        _comment = State(initialValue: request.comment)
        _dictation = State(initialValue: VoiceRecorder(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("Comment Dictation", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)))
    }

    private var trimmed: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dictating: Bool { dictation.phase != .idle }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    reference
                    field
                    if dictation.phase == .preparing {
                        Text(dictation.preparation).font(.footnote).foregroundStyle(.secondary)
                    } else if dictation.phase == .recording || dictation.phase == .finishing, let words = dictation.transcript, !words.isEmpty {
                        Text(words).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
            }
            .navigationTitle(request.draft == nil ? "Add a Comment" : "Edit Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: confirm).disabled(trimmed.isEmpty || dictating)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .formSheetSizing()
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
        .onDisappear { Task { await dictation.discard() } }
        .onChange(of: dictation.phase) { _, phase in
            switch phase {
            case .ready:
                if let words = dictation.transcript { comment = [trimmed, words].filter { !$0.isEmpty }.joined(separator: " ") }
                Task { await dictation.discard() }
            case .failed:
                problem = dictation.hasAudio ? "No speech recognised." : dictation.error
                Task { await dictation.discard() }
            default:
                break
            }
        }
    }

    @ViewBuilder private var reference: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let png = request.markedPNG, let image = Self.around(png, region: request.region) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("The marked area, outlined in orange")
                HStack(alignment: .firstTextBaseline) {
                    Text("Selected image region").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(request.sourceFilename).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } else if let quote = request.shownQuote ?? request.quote {
                Text(quote)
                    .font(request.monospaced ? .system(.footnote, design: .monospaced) : .subheadline)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Capsule().fill(.orange).frame(width: 3) }
                Text(request.caption ?? request.sourceFilename).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Whole attachment").font(.subheadline.weight(.semibold))
                Text(request.sourceFilename).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $comment)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(.horizontal, 10).padding(.vertical, 6).padding(.trailing, 34)
                .accessibilityLabel("Comment")
            if comment.isEmpty {
                Text("What should change?").foregroundStyle(.tertiary)
                    .padding(.horizontal, 15).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) { dictateButton.padding(8) }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var dictateButton: some View {
        switch dictation.phase {
        case .preparing, .finishing:
            ProgressView().frame(width: 32, height: 32)
        case .recording:
            Button { Task { await dictation.finish() } } label: {
                Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop Dictating")
        default:
            Button {
                problem = nil
                dictation.start()
            } label: {
                Image(systemName: "mic").font(.title3).foregroundStyle(.secondary).frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dictate")
        }
    }

    private func confirm() {
        do {
            try save(trimmed)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The marked picture around its region, so a small part of a tall screen still shows.
    private static func around(_ png: Data, region: LinkAnnotation.Region?) -> UIImage? {
        guard let image = UIImage(data: png), let cgImage = image.cgImage else { return nil }
        guard let region else { return image }
        let crop = AnnotationNotes.focus(on: region, in: CGSize(width: cgImage.width, height: cgImage.height))
        return cgImage.cropping(to: crop).map { UIImage(cgImage: $0) } ?? image
    }
}

// MARK: - Marking a region

/// The frozen still of a preview, on which a drag marks the part a comment is about. Lifting the
/// finger hands over the part marked; the comment sheet opens straight away.
struct RegionMarkingCanvas: View {
    let snapshot: UIImage
    @Binding var selection: CGRect?
    let marked: (LinkAnnotation.Region) -> Void
    /// The hint goes once the first drag starts.
    @State private var started = false

    var body: some View {
        GeometryReader { proxy in
            let image = AnnotationNotes.fitted(snapshot.size, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: snapshot).resizable()
                    .frame(width: image.width, height: image.height)
                    .offset(x: image.minX, y: image.minY)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    if let selection { path.addRect(selection) }
                }
                .fill(.black.opacity(selection == nil ? 0 : 0.25), style: FillStyle(eoFill: true))
                if let selection {
                    Rectangle().fill(.orange.opacity(0.14))
                        .overlay(Rectangle().stroke(.orange, lineWidth: 3))
                        .frame(width: selection.width, height: selection.height)
                        .offset(x: selection.minX, y: selection.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    started = true
                    let origin = value.startLocation
                    let box = CGRect(x: min(origin.x, value.location.x), y: min(origin.y, value.location.y),
                                     width: abs(value.location.x - origin.x), height: abs(value.location.y - origin.y)).intersection(image)
                    selection = box.isNull ? nil : box
                }
                .onEnded { value in
                    let box = AnnotationNotes.selection(from: value.startLocation, to: value.location, in: image)
                    selection = box.isNull ? nil : box
                    if let region = AnnotationNotes.region(of: box, in: image) { marked(region) }
                })
            .overlay(alignment: .top) {
                if !started {
                    Label("Drag to mark an area", systemImage: "hand.draw")
                        .font(.headline)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 24)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: started)
        }
        .accessibilityLabel("Select an area to comment on")
    }
}

// MARK: - Notes in the composer and the conversation

/// A note waiting to go with the next message: its picture, the start of its comment, and a button to
/// take it back out. Tapping it edits the comment.
struct AnnotationDraftChip: View {
    let draft: AnnotationDrafts.Draft
    let file: URL
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: edit) {
                HStack(spacing: 10) {
                    thumbnail
                    Text(draft.annotation.comment).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(width: 128, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Comment: \(draft.annotation.comment)")
            .accessibilityHint("Edit")
            Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Comment")
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.orange.opacity(0.35)))
    }

    private var thumbnail: some View {
        Group {
            if draft.annotation.region != nil, let image = DecodedImages.downsampled(file, to: 120) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "text.quote").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemBackground))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "text.bubble.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(.orange, in: Circle())
                .offset(x: 5, y: 5)
        }
        .padding(.trailing, 4)
    }
}

/// A note in the conversation, as the Mac shows one: the part marked or the text quoted, the comment,
/// and the file it is about.
struct AnnotationCard: View {
    let note: LinkAnnotation
    /// The marked picture, for a note on part of a preview.
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Annotation", systemImage: "text.bubble.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            if note.region != nil {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Color(.tertiarySystemBackground).frame(height: 140).overlay { ProgressView() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let quote = note.quote {
                Text(quote).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Capsule().fill(.orange).frame(width: 3) }
            }
            Text(note.comment).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Text(note.sourceFilename).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.orange.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }
}
