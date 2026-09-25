import Foundation
import NoodleCore

/// Places and routes from Apple Maps for every bot. The provider parses and formats;
/// `MapsService` is the only part that talks to MapKit.
public struct MapsToolProvider: ToolProvider {
    public let kind = ToolProviderKind.appExtension
    public let manifest = ToolProviderManifest(
        id: "maps", title: "Maps", summary: "Find places, look up addresses and plan routes with Apple Maps.",
        instructions: """
        search finds places and businesses by name or kind, such as "coffee" --near "Soho, London". \
        geocode turns an address into coordinates, or coordinates written as latitude,longitude into an address. \
        directions plans a route --from one place --to another by driving, walking, cycling or transit, with the distance, travel time and turn-by-turn steps. \
        Transit gives times but no steps. \
        Maps cannot see where this Mac is: when the person does not say where they are, ask them. \
        Every result has an Apple Maps url. Put it in your reply on its own and Noodle shows it as a map that opens Maps when clicked; \
        do not rewrite it as a Markdown link. \
        Apple limits how often a Mac can ask, so do not repeat a search that has already answered.
        """)
    private let service: any MapsService
    private let timeZone: TimeZone

    public init() { self.init(service: MapKitService()) }
    init(service: any MapsService, timeZone: TimeZone = .current) { self.service = service; self.timeZone = timeZone }

    public func tools(context: ToolCallContext) async throws -> Data {
        func tool(_ name: String, _ description: String, required: [String], _ properties: [String: Any]) -> [String: Any] {
            ["name": name, "description": description,
             "annotations": ["readOnlyHint": true, "idempotentHint": true, "openWorldHint": true], "_meta": ["noodle/timeout": 60],
             "inputSchema": ["type": "object", "required": required, "properties": properties]]
        }
        let place = "A place name, an address, or coordinates written as latitude,longitude."
        return try JSONSerialization.data(withJSONObject: ["tools": [
            tool("search", "Find places and businesses. Returns each place's name, address, coordinates, phone, website and Apple Maps url.",
                 required: ["query"], [
                    "query": ["type": "string", "description": "What to look for, such as a name, a kind of place or an address."],
                    "near": ["type": "string", "description": "Search around this place. \(place)"],
                    "limit": ["type": "integer", "description": "Maximum places to return, 1–25. Default 10."]]),
            tool("geocode", "Find the coordinates of an address, or the address at coordinates.", required: ["place"], [
                "place": ["type": "string", "description": place]]),
            tool("directions", "Plan a route. Returns the distance, travel time, steps and an Apple Maps url.", required: ["from", "to"], [
                "from": ["type": "string", "description": "Where the route starts. \(place)"],
                "to": ["type": "string", "description": "Where the route ends. \(place)"],
                "mode": ["type": "string", "enum": MapsMode.allCases.map(\.rawValue), "description": "How to travel. Default driving."],
                "depart": ["type": "string", "description": "Leave at this ISO 8601 date and time. Default now."],
                "arrive": ["type": "string", "description": "Arrive by this ISO 8601 date and time, instead of --depart."],
                "alternatives": ["type": "boolean", "description": "Also return other routes when there are any."],
                "avoid": ["type": "array", "items": ["type": "string", "enum": ["tolls", "highways"]], "description": "Roads to avoid when driving."]]),
        ]], options: [.sortedKeys])
    }

    public func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
        do {
            let options = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
            func text(_ name: String) throws -> String {
                guard let value = (options[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    throw ToolProviderError("Specify --\(name).")
                }
                return value
            }
            switch tool {
            case "search":
                let query = try text("query")
                let near = try (options["near"] as? String).map { try MapsLocation(parsing: $0) }
                let found = try await service.search(query, near: near, limit: min(max(options["limit"] as? Int ?? 10, 1), 25))
                return try places(found, empty: "Apple Maps found nothing for \(query).")
            case "geocode":
                let place = try text("place")
                return try places(try await service.geocode(try MapsLocation(parsing: place)), empty: "Apple Maps found no place for \(place).")
            case "directions":
                let from = try MapsLocation(parsing: try text("from")), to = try MapsLocation(parsing: try text("to"))
                guard let mode = MapsMode(rawValue: options["mode"] as? String ?? "driving") else {
                    throw ToolProviderError("--mode must be driving, walking, cycling or transit.")
                }
                let departure = try date("depart", options), arrival = try date("arrive", options)
                guard departure == nil || arrival == nil else { throw ToolProviderError("Pass --depart or --arrive, not both.") }
                let avoid = Set(options["avoid"] as? [String] ?? [])
                guard avoid.isSubset(of: ["tolls", "highways"]) else { throw ToolProviderError("--avoid takes tolls and highways.") }
                let request = MapsDirectionsRequest(from: from, to: to, mode: mode, departure: departure, arrival: arrival,
                                                    alternatives: options["alternatives"] as? Bool == true,
                                                    avoidTolls: avoid.contains("tolls"), avoidHighways: avoid.contains("highways"))
                return try routes(try await service.directions(request), request: request)
            default:
                throw ToolProviderError("Maps has no tool named \(tool).")
            }
        } catch {
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true], options: [.sortedKeys])
        }
    }

    private func date(_ name: String, _ options: [String: Any]) throws -> Date? {
        guard let value = options[name] as? String else { return nil }
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw ToolProviderError("--\(name) must be an ISO 8601 date and time, such as 2026-09-26T08:30:00-07:00.")
        }
        return date
    }

    private func places(_ places: [MapsPlace], empty: String) throws -> Data {
        let lines = places.enumerated().map { index, place in
            // Addresses found by geocoding are named after their first line.
            let label = place.address.map { $0.hasPrefix(place.name) ? $0 : "\(place.name), \($0)" } ?? place.name
            return "\(index + 1). \(label) (\(Self.number(place.latitude)), \(Self.number(place.longitude))) \(place.url.absoluteString)"
        }
        let structured: [[String: Any]] = places.map { place in
            var entry: [String: Any] = ["name": place.name, "latitude": place.latitude, "longitude": place.longitude, "url": place.url.absoluteString]
            entry["address"] = place.address; entry["category"] = place.category; entry["phone"] = place.phone
            entry["website"] = place.website?.absoluteString
            return entry
        }
        return try Self.result(lines.isEmpty ? empty : lines.joined(separator: "\n"), ["places": structured])
    }

    private func routes(_ routes: [MapsRoute], request: MapsDirectionsRequest) throws -> Data {
        guard !routes.isEmpty else { throw ToolProviderError("Apple Maps found no route between these places.") }
        let formatter = ISO8601DateFormatter(); formatter.timeZone = timeZone
        let url = request.url
        var lines: [String] = []
        for (index, route) in routes.enumerated() {
            var summary = "\(route.from.name) to \(route.to.name) \(request.mode.phrase)"
            if !route.name.isEmpty { summary += " via \(route.name)" }
            summary += ": \(Self.distance(route.distance, miles: true)), \(Self.duration(route.duration))"
            if let departure = route.departure { summary += ", leaving \(formatter.string(from: departure))" }
            if let arrival = route.arrival { summary += ", arriving \(formatter.string(from: arrival))" }
            summary += "."
            for note in (route.hasTolls ? ["Has tolls"] : []) + route.advisories {
                summary += " \(note)\(note.hasSuffix(".") ? "" : ".")"
            }
            lines.append(routes.count == 1 ? summary : "Route \(index + 1): \(summary)")
            let steps = route.steps.filter { !$0.instruction.isEmpty }
            for (number, step) in steps.enumerated() {
                lines.append("\(number + 1). \(step.instruction)" + (step.distance > 0 ? " (\(Self.distance(step.distance, miles: false)))" : ""))
            }
        }
        lines.append(url.absoluteString)
        let structured: [[String: Any]] = routes.map { route in
            var entry: [String: Any] = [
                "from": route.from.name, "to": route.to.name, "name": route.name,
                "distanceMeters": route.distance, "durationSeconds": route.duration,
                "hasTolls": route.hasTolls, "hasHighways": route.hasHighways, "advisories": route.advisories,
                "steps": route.steps.filter { !$0.instruction.isEmpty }.map { ["instruction": $0.instruction, "distanceMeters": $0.distance] }]
            entry["departure"] = route.departure.map(formatter.string(from:))
            entry["arrival"] = route.arrival.map(formatter.string(from:))
            return entry
        }
        return try Self.result(lines.joined(separator: "\n"), ["routes": structured, "url": url.absoluteString])
    }

    private static func distance(_ meters: Double, miles: Bool) -> String {
        let metric = meters < 1_000 ? "\(Int((meters / 10).rounded()) * 10) m" : String(format: "%.1f km", meters / 1_000)
        return miles ? "\(metric) (\(String(format: "%.1f", meters / 1_609.344)) mi)" : metric
    }
    private static func duration(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h" + (minutes % 60 == 0 ? "" : " \(minutes % 60) min")
    }
    static func number(_ value: Double) -> String {
        String(format: "%.6f", value).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
    private static func result(_ text: String, _ structured: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "structuredContent": structured, "isError": false], options: [.sortedKeys])
    }
}

/// What the tools need from Apple Maps, so they can be tested without it.
protocol MapsService: Sendable {
    func search(_ query: String, near: MapsLocation?, limit: Int) async throws -> [MapsPlace]
    func geocode(_ location: MapsLocation) async throws -> [MapsPlace]
    func directions(_ request: MapsDirectionsRequest) async throws -> [MapsRoute]
}

enum MapsLocation: Equatable, Sendable {
    case coordinate(Double, Double)
    case text(String)

    init(parsing value: String) throws {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.caseInsensitiveCompare("Current Location") != .orderedSame else {
            throw ToolProviderError("Maps cannot see where this Mac is. Ask the person where they are starting from.")
        }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let latitude = parts[0], let longitude = parts[1] else { self = .text(text); return }
        guard abs(latitude) <= 90, abs(longitude) <= 180 else {
            throw ToolProviderError("Latitude must be between -90 and 90 and longitude between -180 and 180.")
        }
        self = .coordinate(latitude, longitude)
    }

    /// How an Apple Maps link writes this location.
    var query: String {
        switch self {
        case let .coordinate(latitude, longitude): "\(MapsToolProvider.number(latitude)),\(MapsToolProvider.number(longitude))"
        case let .text(text): text
        }
    }
}

enum MapsMode: String, CaseIterable, Sendable {
    case driving, walking, cycling, transit
    var phrase: String {
        switch self {
        case .driving: "by car"
        case .walking: "on foot"
        case .cycling: "by bike"
        case .transit: "by transit"
        }
    }
}

struct MapsPlace: Equatable, Sendable {
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var category: String?
    var phone: String?
    var website: URL?
    init(name: String, address: String?, latitude: Double, longitude: Double,
         category: String? = nil, phone: String? = nil, website: URL? = nil) {
        self.name = name; self.address = address; self.latitude = latitude; self.longitude = longitude
        self.category = category; self.phone = phone; self.website = website
    }
    var url: URL {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "ll", value: MapsLocation.coordinate(latitude, longitude).query),
                                 URLQueryItem(name: "q", value: name)]
        return components.url!
    }
}

struct MapsDirectionsRequest: Equatable, Sendable {
    var from: MapsLocation
    var to: MapsLocation
    var mode: MapsMode
    var departure: Date?
    var arrival: Date?
    var alternatives = false
    var avoidTolls = false
    var avoidHighways = false
    init(from: MapsLocation, to: MapsLocation, mode: MapsMode, departure: Date? = nil, arrival: Date? = nil,
         alternatives: Bool = false, avoidTolls: Bool = false, avoidHighways: Bool = false) {
        self.from = from; self.to = to; self.mode = mode; self.departure = departure; self.arrival = arrival
        self.alternatives = alternatives; self.avoidTolls = avoidTolls; self.avoidHighways = avoidHighways
    }
    /// Opens the same route in Maps. It keeps what the bot asked for, so Maps resolves it the same way.
    var url: URL {
        var components = URLComponents(string: "https://maps.apple.com/directions")!
        components.queryItems = [URLQueryItem(name: "source", value: from.query), URLQueryItem(name: "destination", value: to.query),
                                 URLQueryItem(name: "mode", value: mode.rawValue)]
        return components.url!
    }
}

struct MapsStep: Equatable, Sendable {
    var instruction: String
    var distance: Double
}

struct MapsRoute: Equatable, Sendable {
    var from: MapsPlace
    var to: MapsPlace
    var name: String
    var distance: Double
    var duration: Double
    var departure: Date?
    var arrival: Date?
    var steps: [MapsStep]
    var advisories: [String]
    var hasTolls: Bool
    var hasHighways: Bool
    init(from: MapsPlace, to: MapsPlace, name: String, distance: Double, duration: Double,
         steps: [MapsStep] = [], advisories: [String] = [], hasTolls: Bool = false, hasHighways: Bool = false) {
        self.from = from; self.to = to; self.name = name; self.distance = distance; self.duration = duration
        self.steps = steps; self.advisories = advisories; self.hasTolls = hasTolls; self.hasHighways = hasHighways
    }
}
