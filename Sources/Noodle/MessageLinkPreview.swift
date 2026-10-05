import AppKit
import CryptoKit
import MapKit
import NoodleCore
import SwiftUI
@preconcurrency import LinkPresentation

struct MessageLinkPreview: View {
    let url: URL
    let shouldLoad: Bool
    private let cache: LinkPreviewMetadataCache?
    private let openURL: ((URL) -> Void)?
    @Environment(\.openURL) private var environmentOpenURL

    init(url: URL, shouldLoad: Bool, cache: LinkPreviewMetadataCache? = nil, openURL: ((URL) -> Void)? = nil) {
        self.url = url; self.shouldLoad = shouldLoad; self.cache = cache; self.openURL = openURL
    }

    var body: some View {
        Button {
            if let openURL { openURL(url) } else { environmentOpenURL(url) }
        } label: {
            LinkPreviewCard(url: url, shouldLoad: shouldLoad, cache: cache)
        }
        .buttonStyle(.plain)
    }
}

/// A web page's picture, title and site, as unfurled from a message or shared as a link attachment.
struct LinkPreviewCard: View {
    static let cardWidth: CGFloat = 280
    static let imageHeight: CGFloat = 158
    /// How long a card stays in view before its page is fetched.
    static let fetchDelay: Duration = .milliseconds(300)
    private let cardHeight: CGFloat = 220
    private var cardWidth: CGFloat { Self.cardWidth }
    private var imageHeight: CGFloat { Self.imageHeight }

    let url: URL
    let shouldLoad: Bool
    private let cache: LinkPreviewMetadataCache

    @State private var metadata: LPLinkMetadata?
    @State private var previewImage: NSImage?
    @State private var requested = false
    @State private var loading = false
    @State private var requestID = UUID()

    @MainActor init(url: URL, shouldLoad: Bool, cache: LinkPreviewMetadataCache? = nil) {
        self.url = url; self.shouldLoad = shouldLoad
        let cache = cache ?? .shared
        self.cache = cache
        // Lazy rows need their cached content before the first visible frame.
        let result = cache.cachedResult(for: url)
        _metadata = State(initialValue: result?.metadata)
        _previewImage = State(initialValue: result?.image)
        _requested = State(initialValue: result != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black.opacity(0.28)
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: imageHeight, alignment: .topLeading)
                        .clipped()
                        .transition(.opacity)
                } else if loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: mapLink == nil ? "link" : "map")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                }
                if isYouTubeLink, metadata != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.7), in: Circle())
                }
            }
            .frame(width: cardWidth, height: imageHeight)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(siteLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: cardWidth, alignment: .leading)
            .frame(minHeight: cardHeight - imageHeight, alignment: .leading)
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mapLink == nil ? "Open link: \(title)" : "Open in Maps: \(title)")
        .onChange(of: url) { _, _ in
            requestID = UUID()
            restoreCachedResult()
            if shouldLoad { requestMetadata() }
        }
        .task(id: shouldLoad) {
            // Starting a fetch blocks the main thread, so a row only scrolled past starts none.
            guard shouldLoad, (try? await Task.sleep(for: Self.fetchDelay)) != nil else { return }
            requestMetadata()
        }
    }

    @discardableResult
    private func restoreCachedResult() -> Bool {
        let result = cache.cachedResult(for: url)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            metadata = result?.metadata
            previewImage = result?.image
            requested = result != nil
            loading = false
        }
        return result != nil
    }

    private func requestMetadata() {
        // Another row may have filled the cache while this one was offscreen.
        guard !requested, !restoreCachedResult() else { return }
        requested = true
        loading = true
        let id = requestID
        cache.load(url) { result in
            guard requestID == id else { return }
            metadata = result.metadata
            loading = false
            withAnimation(.easeOut(duration: 0.15)) {
                previewImage = result.image
            }
        }
    }

    private var mapLink: MapLink? { MapLink(url) }

    private var title: String {
        mapLink?.title ?? metadata?.title ?? url.host ?? url.absoluteString
    }

    private var siteLabel: String {
        if mapLink != nil { return "Apple Maps" }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var isYouTubeLink: Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

/// Holding ⌘, ⌥ or ⇧ while opening a link or attachment skips Quick Look and opens it on its own.
enum QuickLookBypass {
    static func isHeld(_ modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        !modifiers.intersection([.command, .option, .shift]).isEmpty
    }
}

/// Web links open in Quick Look first, whose Open button hands them to the browser.
enum WebLinkPreview {
    static let defaultsKey = "Noodle.webLinks.preview"
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
    static func opensInPreview(in defaults: UserDefaults = .standard,
                               modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        isEnabled(in: defaults) && !QuickLookBypass.isHeld(modifiers)
    }
    /// The link to show in Quick Look, or nil when it goes straight to the system.
    static func previewed(_ url: URL, enabled: Bool) -> URL? {
        guard enabled, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
    /// Quick Look renders a web page from a .webloc bookmark, as it does for link attachments.
    static func bookmark(for url: URL, in directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Web Links", isDirectory: true)) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name + ".webloc")
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        try data.write(to: file, options: .atomic)
        return file
    }
    /// The unsaved link attachment an annotation refers to, named as an attached link would be.
    static func source(for url: URL, conversationID: UUID) throws -> (source: ConversationAttachment, data: Data) {
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        let name = (url.host ?? "Link") + ".webloc"
        return (ConversationAttachment(conversationID: conversationID, originalFilename: name, storedFilename: name,
            mediaType: "application/x-webloc", byteCount: Int64(data.count), url: url), data)
    }
}

/// Link previews, kept on this Mac for a week, then fetched again so they do not go stale. A preview
/// that could not be fetched is kept for this launch only.
@MainActor
final class LinkPreviewMetadataCache {
    static let shared = LinkPreviewMetadataCache(folder: .cachesDirectory.appendingPathComponent("Link Previews", isDirectory: true))
    static let lifetime: TimeInterval = 7 * 86_400
    static let timeout: TimeInterval = 10
    final class Result: NSObject {
        let metadata: LPLinkMetadata?
        let image: NSImage?
        let savedAt: Date
        init(metadata: LPLinkMetadata?, image: NSImage?, savedAt: Date = Date()) {
            self.metadata = metadata
            self.image = image
            self.savedAt = savedAt
        }
    }
    private struct Saved: Codable {
        var fetched: Bool
        var title: String?
        var image: Data?
        var savedAt: Date
    }
    private final class Request {
        var metadata: LPLinkMetadata?
        var completions: [(Result) -> Void] = []
        var cancellations: [() -> Void] = []
        var deadline: Task<Void, Never>?
    }
    typealias MetadataLoader = (URL, TimeInterval, @escaping (LPLinkMetadata?) -> Void) -> (() -> Void)
    typealias ImageLoader = (NSItemProvider, @escaping (NSImage?) -> Void) -> (() -> Void)
    typealias MapLoader = (MapLink, TimeInterval, @escaping (NSImage?) -> Void) -> (() -> Void)
    private let fetchMetadata: MetadataLoader
    private let fetchImage: ImageLoader
    private let fetchMap: MapLoader
    private let sleep: (Duration) async throws -> Void
    private let folder: URL?
    private let now: () -> Date
    private let cache = NSCache<NSURL, Result>()
    private var pending: [URL: Request] = [:]

    init(fetchMetadata: @escaping MetadataLoader = LinkPreviewMetadataCache.nativeMetadata,
         fetchImage: @escaping ImageLoader = LinkPreviewMetadataCache.nativeImage,
         fetchMap: @escaping MapLoader = MapSnapshot.render,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         folder: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fetchMetadata = fetchMetadata
        self.fetchImage = fetchImage
        self.fetchMap = fetchMap
        self.sleep = sleep
        self.folder = folder
        self.now = now
        cache.countLimit = 128
        for file in folder.flatMap({ try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }) ?? []
        where !(saved(at: file).map { isFresh($0.savedAt) } ?? false) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func cachedResult(for url: URL) -> Result? {
        if let result = cache.object(forKey: url as NSURL) {
            if isFresh(result.savedAt) { return result }
            cache.removeObject(forKey: url as NSURL)
        }
        guard let file = file(for: url), let saved = saved(at: file) else { return nil }
        guard isFresh(saved.savedAt) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        var metadata: LPLinkMetadata?
        if saved.fetched {
            metadata = LPLinkMetadata()
            metadata?.originalURL = url
            metadata?.url = url
            metadata?.title = saved.title
        }
        let result = Result(metadata: metadata, image: saved.image.flatMap(NSImage.init(data:)).map(Self.cardPicture),
                            savedAt: saved.savedAt)
        cache.setObject(result, forKey: url as NSURL)
        return result
    }
    func load(_ url: URL, timeout: TimeInterval = LinkPreviewMetadataCache.timeout, completion: @escaping (Result) -> Void) {
        if let result = cachedResult(for: url) {
            completion(result)
            return
        }
        if let request = pending[url] {
            request.completions.append(completion)
            return
        }
        let request = Request()
        request.completions = [completion]
        pending[url] = request
        // One deadline covers metadata AND its image, independently of whether
        // Apple's callbacks arrive. Every terminal outcome stops the spinner.
        let sleep = sleep
        request.deadline = Task { [weak self, weak request] in
            try? await sleep(.seconds(max(0.01, timeout)))
            guard !Task.isCancelled, let request else { return }
            self?.finish(url, request: request, image: nil)
        }
        // The Apple Maps page has no useful preview; draw the place or route instead.
        if let link = MapLink(url) {
            request.cancellations.append(fetchMap(link, timeout) { [weak self, weak request] image in
                Task { @MainActor in
                    guard let request else { return }
                    self?.finish(url, request: request, image: image)
                }
            })
            return
        }
        request.cancellations.append(fetchMetadata(url, timeout) { [weak self, weak request] metadata in
            Task { @MainActor in
                guard let self, let request, self.pending[url] === request else { return }
                request.metadata = metadata
                guard let provider = metadata?.imageProvider ?? metadata?.iconProvider else {
                    self.finish(url, request: request, image: nil)
                    return
                }
                request.cancellations.append(self.fetchImage(provider) { [weak self, weak request] image in
                    Task { @MainActor in
                        guard let request else { return }
                        self?.finish(url, request: request, image: image)
                    }
                })
            }
        })
    }
    private func finish(_ url: URL, request: Request, image: NSImage?) {
        guard pending[url] === request else { return }
        pending[url] = nil
        request.deadline?.cancel()
        request.cancellations.forEach { $0() }
        let result = Result(metadata: request.metadata, image: image.map(Self.cardPicture), savedAt: now())
        // Cache failures too, for this launch: rebuilding visible rows must not start retry loops.
        cache.setObject(result, forKey: url as NSURL)
        if request.metadata != nil || image != nil, let file = file(for: url) {
            let png = result.image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
            let saved = Saved(fetched: request.metadata != nil, title: request.metadata?.title, image: png, savedAt: result.savedAt)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
        }
        request.completions.forEach { $0(result) }
    }
    /// A web page's picture scaled down to cover its card at twice the card's size, for Retina displays.
    /// Scrolled rows redraw it constantly, and a full-size picture had to be decoded again on every redraw.
    static func cardPicture(_ image: NSImage) -> NSImage {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let scale = max(LinkPreviewCard.cardWidth * 2 / CGFloat(source.width),
                        LinkPreviewCard.imageHeight * 2 / CGFloat(source.height))
        guard scale < 1 else { return image }
        let width = Int((CGFloat(source.width) * scale).rounded(.up))
        let height = Int((CGFloat(source.height) * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) } ?? image
    }
    private func isFresh(_ savedAt: Date) -> Bool { now().timeIntervalSince(savedAt) < Self.lifetime }
    private func file(for url: URL) -> URL? {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name + ".json")
    }
    private func saved(at file: URL) -> Saved? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }
    nonisolated static func nativeMetadata(_ url: URL, timeout: TimeInterval, completion: @escaping (LPLinkMetadata?) -> Void) -> (() -> Void) {
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        provider.startFetchingMetadata(for: url) { metadata, error in
            completion(error == nil ? metadata : nil)
        }
        return { provider.cancel() }
    }
    nonisolated static func nativeImage(_ provider: NSItemProvider, completion: @escaping (NSImage?) -> Void) -> (() -> Void) {
        let progress = provider.loadObject(ofClass: NSImage.self) { object, _ in
            completion(object as? NSImage)
        }
        return { progress.cancel() }
    }
}

/// A place or route described by an Apple Maps link, in both the classic query form and
/// the newer `/directions`, `/place` and `/search` paths.
struct MapLink: Equatable {
    enum Place: Equatable {
        case coordinate(Double, Double)
        case address(String)
        init?(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
                  text.caseInsensitiveCompare("Current Location") != .orderedSame else { return nil }
            let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let latitude = parts[0], let longitude = parts[1] {
                guard abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
                self = .coordinate(latitude, longitude)
            } else {
                self = .address(text)
            }
        }
    }
    enum Transport: Equatable { case driving, walking, transit, cycling }

    var from: Place?
    var to: Place
    var directions = false
    var transport = Transport.driving
    var name: String?

    init(from: Place?, to: Place, directions: Bool = false, transport: Transport = .driving, name: String? = nil) {
        self.from = from; self.to = to; self.directions = directions; self.transport = transport; self.name = name
    }

    init?(_ url: URL) {
        guard url.host?.lowercased() == "maps.apple.com",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value?.replacingOccurrences(of: "+", with: " ")
        }
        let name = query["name"] ?? query["q"]
        switch url.path.lowercased() {
        case "/directions":
            guard let to = Place(query["destination"]) else { return nil }
            let transport: Transport = switch query["mode"]?.lowercased() {
            case "walking": .walking
            case "transit": .transit
            case "cycling": .cycling
            default: .driving
            }
            self.init(from: Place(query["source"]), to: to, directions: true, transport: transport)
        case "/place":
            guard let to = Place(query["coordinate"]) ?? Place(query["address"]) ?? Place(query["name"]) else { return nil }
            self.init(from: nil, to: to, name: name)
        case "/search":
            guard let to = Place(query["query"]) else { return nil }
            self.init(from: nil, to: to)
        case "", "/":
            if query["daddr"] != nil {
                guard let to = Place(query["daddr"]) else { return nil }
                let transport: Transport = switch query["dirflg"]?.lowercased() {
                case "w": .walking
                case "r": .transit
                case "c": .cycling
                default: .driving
                }
                self.init(from: Place(query["saddr"]), to: to, directions: true, transport: transport)
            } else if query["ll"] != nil {
                guard let to = Place(query["ll"]), case .coordinate = to else { return nil }
                self.init(from: nil, to: to, name: name)
            } else if let to = Place(query["address"]) ?? Place(query["q"]) {
                self.init(from: nil, to: to, name: query["address"] == nil ? nil : query["q"])
            } else {
                return nil
            }
        default:
            return nil
        }
    }

    var title: String {
        var label: String? { if case let .address(text) = to { text } else { nil } }
        if directions { return label.map { "Directions to \($0)" } ?? "Directions" }
        return name ?? label ?? "Map"
    }
}

/// Draws a map link into a card image: the route when Maps can plan one, otherwise pins.
enum MapSnapshot {
    static let size = CGSize(width: 280, height: 158)

    nonisolated static func render(_ link: MapLink, timeout: TimeInterval, completion: @escaping (NSImage?) -> Void) -> (() -> Void) {
        let task = Task { completion(await image(for: link)) }
        return { task.cancel() }
    }

    private static func image(for link: MapLink) async -> NSImage? {
        guard let destination = await mapItem(link.to) else { return nil }
        let origin = await link.from.asyncFlatMap(mapItem)
        var route: MKPolyline?
        if link.directions, let origin, link.transport != .transit {
            let request = MKDirections.Request()
            request.source = origin; request.destination = destination
            request.transportType = switch link.transport {
            case .walking: .walking
            case .cycling: .cycling
            default: .automobile
            }
            route = try? await MKDirections(request: request).calculate().routes.first?.polyline
        }
        let points = [origin, destination].compactMap { $0?.location.coordinate }
        guard !Task.isCancelled else { return nil }

        let options = MKMapSnapshotter.Options()
        options.size = size
        let appearance = await MainActor.run { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) }
        options.appearance = appearance.flatMap(NSAppearance.init(named:))
        if let route {
            options.mapRect = route.boundingMapRect.insetBy(dx: -route.boundingMapRect.width * 0.15,
                                                            dy: -route.boundingMapRect.height * 0.15)
        } else {
            options.mapRect = region(around: points)
        }
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            snapshot.image.draw(in: rect)
            if let route {
                let path = NSBezierPath()
                let coordinates = route.coordinates
                for (index, coordinate) in coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    index == 0 ? path.move(to: point) : path.line(to: point)
                }
                path.lineJoinStyle = .round; path.lineCapStyle = .round
                NSColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = 6; path.stroke()
                NSColor.systemBlue.setStroke(); path.lineWidth = 3.5; path.stroke()
            }
            for (index, coordinate) in points.enumerated() {
                let center = snapshot.point(for: coordinate)
                let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                (index == points.count - 1 ? NSColor.systemRed : NSColor.white).setFill(); dot.fill()
                (index == points.count - 1 ? NSColor.white : NSColor.systemBlue).setStroke(); dot.lineWidth = 2.5; dot.stroke()
            }
            return true
        }
    }

    private static func mapItem(_ place: MapLink.Place) async -> MKMapItem? {
        switch place {
        case let .coordinate(latitude, longitude):
            return MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
        case let .address(text):
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            return try? await MKLocalSearch(request: request).start().mapItems.first
        }
    }

    /// A neighbourhood around one point, or every point with some margin.
    private static func region(around points: [CLLocationCoordinate2D]) -> MKMapRect {
        let rects = points.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
        let bounds = rects.dropFirst().reduce(rects.first ?? .null) { $0.union($1) }
        let minimum = MKMapPointsPerMeterAtLatitude(points.first?.latitude ?? 0) * 1_500
        let width = max(bounds.width * 1.3, minimum), height = max(bounds.height * 1.3, minimum * size.height / size.width)
        return MKMapRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
