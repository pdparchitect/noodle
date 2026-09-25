import AppKit
import MapKit
import SwiftUI
@preconcurrency import LinkPresentation

struct MessageLinkPreview: View {
    private let cardWidth: CGFloat = 280
    private let imageHeight: CGFloat = 158
    private let cardHeight: CGFloat = 220

    let url: URL
    let shouldLoad: Bool
    private let cache: LinkPreviewMetadataCache
    private let openURL: (URL) -> Void

    @State private var metadata: LPLinkMetadata?
    @State private var previewImage: NSImage?
    @State private var requested = false
    @State private var loading = false
    @State private var requestID = UUID()

    @MainActor init(url: URL, shouldLoad: Bool, cache: LinkPreviewMetadataCache? = nil,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.url = url; self.shouldLoad = shouldLoad
        let cache = cache ?? .shared
        self.cache = cache; self.openURL = openURL
        // Lazy rows need their cached content before the first visible frame.
        let result = cache.cachedResult(for: url)
        _metadata = State(initialValue: result?.metadata)
        _previewImage = State(initialValue: result?.image)
        _requested = State(initialValue: result != nil)
    }

    var body: some View {
        Button {
            openURL(url)
        } label: {
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mapLink == nil ? "Open link: \(title)" : "Open in Maps: \(title)")
        .onChange(of: url) { _, _ in
            requestID = UUID()
            restoreCachedResult()
            if shouldLoad { requestMetadata() }
        }
        .onChange(of: shouldLoad, initial: true) { _, visible in
            guard visible else { return }
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

enum LinkPreviewSettings {
    static let timeoutKey = "Noodle.linkPreview.timeoutSeconds"
    static let defaultTimeout = 10
    static let timeoutOptions = [5, 10, 20, 30]
    static func timeout(in defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.object(forKey: timeoutKey) as? Int ?? defaultTimeout
        return TimeInterval(min(30, max(5, value)))
    }
}

@MainActor
final class LinkPreviewMetadataCache {
    static let shared = LinkPreviewMetadataCache()
    final class Result: NSObject {
        let metadata: LPLinkMetadata?
        let image: NSImage?
        init(metadata: LPLinkMetadata?, image: NSImage?) {
            self.metadata = metadata
            self.image = image
        }
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
    private let cache = NSCache<NSURL, Result>()
    private var pending: [URL: Request] = [:]

    init(fetchMetadata: @escaping MetadataLoader = LinkPreviewMetadataCache.nativeMetadata,
         fetchImage: @escaping ImageLoader = LinkPreviewMetadataCache.nativeImage,
         fetchMap: @escaping MapLoader = MapSnapshot.render,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.fetchMetadata = fetchMetadata
        self.fetchImage = fetchImage
        self.fetchMap = fetchMap
        self.sleep = sleep
        cache.countLimit = 128
    }
    func cachedResult(for url: URL) -> Result? {
        cache.object(forKey: url as NSURL)
    }
    func load(_ url: URL, timeout: TimeInterval = LinkPreviewSettings.timeout(), completion: @escaping (Result) -> Void) {
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
        let result = Result(metadata: request.metadata, image: image)
        // Cache failures too: rebuilding visible rows must not start retry loops.
        cache.setObject(result, forKey: url as NSURL)
        request.completions.forEach { $0(result) }
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
