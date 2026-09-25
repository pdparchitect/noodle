import MapKit
import NoodleCore
import XCTest
@testable import NoodleMapsTools

private final class FakeMaps: MapsService, @unchecked Sendable {
    var places: [MapsPlace] = []
    var routes: [MapsRoute] = []
    var failure: Error?
    var searches: [(query: String, near: MapsLocation?, limit: Int)] = []
    var geocodes: [MapsLocation] = []
    var requests: [MapsDirectionsRequest] = []
    func search(_ query: String, near: MapsLocation?, limit: Int) async throws -> [MapsPlace] {
        searches.append((query, near, limit)); if let failure { throw failure }; return places
    }
    func geocode(_ location: MapsLocation) async throws -> [MapsPlace] {
        geocodes.append(location); if let failure { throw failure }; return places
    }
    func directions(_ request: MapsDirectionsRequest) async throws -> [MapsRoute] {
        requests.append(request); if let failure { throw failure }; return routes
    }
}

final class MapsToolsTests: XCTestCase {
    private let maps = FakeMaps()
    private lazy var provider = MapsToolProvider(service: maps, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    private let context = ToolCallContext(agentID: UUID(), workspace: URL(fileURLWithPath: "/"))
    private let ferry = MapsPlace(name: "Ferry Building", address: "1 Ferry Building, San Francisco, CA 94111",
                                  latitude: 37.7955, longitude: -122.3937, category: "Store", phone: "+1 415 983 8030",
                                  website: URL(string: "https://www.ferrybuildingmarketplace.com"))
    private let oakland = MapsPlace(name: "Oakland", address: "Oakland, CA", latitude: 37.8044, longitude: -122.2712)

    private func call(_ tool: String, _ arguments: String) async throws -> [String: Any] {
        let data = try await provider.call(tool, arguments: Data(arguments.utf8), files: [], context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }
    private func structured(_ result: [String: Any]) -> [String: Any] { result["structuredContent"] as? [String: Any] ?? [:] }

    func testListsReadOnlyToolsWhoseRequiredArgumentsAreDeclared() async throws {
        let data = try await provider.tools(context: context)
        let tools = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["search", "geocode", "directions"])
        let required = tools.map { ($0["inputSchema"] as? [String: Any])?["required"] as? [String] ?? [] }
        XCTAssertEqual(required, [["query"], ["place"], ["from", "to"]])
        for tool in tools {
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            for name in required[tools.firstIndex { $0["name"] as? String == tool["name"] as? String }!] {
                XCTAssertNotNil(properties[name], name)
            }
        }
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual(provider.manifest.id, "maps")
    }

    func testSearchListsPlacesWithAMapLinkForEach() async throws {
        maps.places = [ferry, oakland]
        let result = try await call("search", #"{"query":"ferry building","near":"37.8,-122.4","limit":40}"#)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(maps.searches.first?.query, "ferry building")
        XCTAssertEqual(maps.searches.first?.near, .coordinate(37.8, -122.4))
        XCTAssertEqual(maps.searches.first?.limit, 25)
        XCTAssertEqual(text(result), """
        1. Ferry Building, 1 Ferry Building, San Francisco, CA 94111 (37.7955, -122.3937) https://maps.apple.com/?ll=37.7955,-122.3937&q=Ferry%20Building
        2. Oakland, CA (37.8044, -122.2712) https://maps.apple.com/?ll=37.8044,-122.2712&q=Oakland
        """)
        let places = try XCTUnwrap(structured(result)["places"] as? [[String: Any]])
        XCTAssertEqual(places.count, 2)
        XCTAssertEqual(places[0]["phone"] as? String, "+1 415 983 8030")
        XCTAssertEqual(places[0]["category"] as? String, "Store")
        XCTAssertEqual(places[0]["website"] as? String, "https://www.ferrybuildingmarketplace.com")
        XCTAssertEqual(places[0]["url"] as? String, "https://maps.apple.com/?ll=37.7955,-122.3937&q=Ferry%20Building")
        XCTAssertNil(places[1]["phone"])

        _ = try await call("search", #"{"query":"coffee","near":"Soho, London"}"#)
        XCTAssertEqual(maps.searches.last?.near, .text("Soho, London"))
        XCTAssertEqual(maps.searches.last?.limit, 10)
    }

    func testGeocodeReadsCoordinatesBackwardsAndAddressesForwards() async throws {
        maps.places = [ferry]
        _ = try await call("geocode", #"{"place":" 37.7955 , -122.3937 "}"#)
        _ = try await call("geocode", #"{"place":"1 Ferry Building, San Francisco"}"#)
        XCTAssertEqual(maps.geocodes, [.coordinate(37.7955, -122.3937), .text("1 Ferry Building, San Francisco")])
        maps.places = []
        let empty = try await call("geocode", #"{"place":"nowhere at all"}"#)
        XCTAssertEqual(text(empty), "Apple Maps found no place for nowhere at all.")

        maps.places = [MapsPlace(name: "1 Infinite Loop", address: "1 Infinite Loop, Cupertino, CA 95014", latitude: 37.3317, longitude: -122.0301)]
        let named = try await call("geocode", #"{"place":"1 Infinite Loop"}"#)
        XCTAssertEqual(text(named),
                       "1. 1 Infinite Loop, Cupertino, CA 95014 (37.3317, -122.0301) https://maps.apple.com/?ll=37.3317,-122.0301&q=1%20Infinite%20Loop")
        XCTAssertEqual(empty["isError"] as? Bool, false)
    }

    func testDirectionsSummariseTheRouteAndLinkToIt() async throws {
        maps.routes = [MapsRoute(from: oakland, to: ferry, name: "I-80 W", distance: 17_675, duration: 2_095,
                                 steps: [MapsStep(instruction: "Turn right onto Broadway", distance: 450),
                                         MapsStep(instruction: "Take the ramp onto I-80 W", distance: 12_300),
                                         MapsStep(instruction: "Arrive at the destination", distance: 0)],
                                 advisories: ["Toll road"], hasTolls: true)]
        let result = try await call("directions", #"{"from":"Oakland","to":"Ferry Building","avoid":["highways"]}"#)
        XCTAssertEqual(maps.requests.first, MapsDirectionsRequest(from: .text("Oakland"), to: .text("Ferry Building"), mode: .driving,
                                                                   avoidTolls: false, avoidHighways: true))
        XCTAssertEqual(text(result), """
        Oakland to Ferry Building by car via I-80 W: 17.7 km (11.0 mi), 35 min. Has tolls. Toll road.
        1. Turn right onto Broadway (450 m)
        2. Take the ramp onto I-80 W (12.3 km)
        3. Arrive at the destination
        https://maps.apple.com/directions?source=Oakland&destination=Ferry%20Building&mode=driving
        """)
        let route = try XCTUnwrap((structured(result)["routes"] as? [[String: Any]])?.first)
        XCTAssertEqual(route["distanceMeters"] as? Double, 17_675)
        XCTAssertEqual(route["durationSeconds"] as? Double, 2_095)
        XCTAssertEqual((route["steps"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(structured(result)["url"] as? String, "https://maps.apple.com/directions?source=Oakland&destination=Ferry%20Building&mode=driving")
    }

    func testTransitDirectionsCarryTheirTimesAndAlternativesAreNumbered() async throws {
        var first = MapsRoute(from: oakland, to: ferry, name: "", distance: 900, duration: 1_500)
        first.departure = Date(timeIntervalSince1970: 1_790_000_000); first.arrival = first.departure! + 1_500
        maps.routes = [first, MapsRoute(from: oakland, to: ferry, name: "", distance: 20_000, duration: 3_700)]
        let result = try await call("directions",
            #"{"from":"37.8044,-122.2712","to":"Ferry Building","mode":"transit","arrive":"2026-09-26T09:00:00-07:00","alternatives":true}"#)
        let request = try XCTUnwrap(maps.requests.first)
        XCTAssertEqual(request.mode, .transit); XCTAssertTrue(request.alternatives)
        XCTAssertEqual(request.from, .coordinate(37.8044, -122.2712))
        XCTAssertEqual(request.arrival, ISO8601DateFormatter().date(from: "2026-09-26T16:00:00Z"))
        XCTAssertNil(request.departure)
        XCTAssertEqual(text(result), """
        Route 1: Oakland to Ferry Building by transit: 900 m (0.6 mi), 25 min, leaving 2026-09-21T07:13:20-07:00, arriving 2026-09-21T07:38:20-07:00.
        Route 2: Oakland to Ferry Building by transit: 20.0 km (12.4 mi), 1 h 2 min.
        https://maps.apple.com/directions?source=37.8044,-122.2712&destination=Ferry%20Building&mode=transit
        """)
    }

    func testBadArgumentsAndServiceFailuresAreToolErrors() async throws {
        let cases: [(String, String, String)] = [
            ("directions", #"{"from":"A","to":"B","depart":"2026-09-26T08:00:00Z","arrive":"2026-09-26T09:00:00Z"}"#, "Pass --depart or --arrive, not both."),
            ("directions", #"{"from":"A","to":"B","depart":"tomorrow"}"#, "--depart must be an ISO 8601 date and time, such as 2026-09-26T08:30:00-07:00."),
            ("directions", #"{"from":"A","to":"B","mode":"flying"}"#, "--mode must be driving, walking, cycling or transit."),
            ("directions", #"{"from":"Current Location","to":"B"}"#, "Maps cannot see where this Mac is. Ask the person where they are starting from."),
            ("directions", #"{"to":"B"}"#, "Specify --from."),
            ("search", #"{"query":"  "}"#, "Specify --query."),
            ("geocode", #"{"place":"91,0"}"#, "Latitude must be between -90 and 90 and longitude between -180 and 180."),
            ("teleport", "{}", "Maps has no tool named teleport."),
        ]
        for (tool, arguments, message) in cases {
            let result = try await call(tool, arguments)
            XCTAssertEqual(result["isError"] as? Bool, true, arguments)
            XCTAssertEqual(text(result), message, arguments)
        }
        XCTAssertTrue(maps.requests.isEmpty && maps.searches.isEmpty && maps.geocodes.isEmpty)

        maps.failure = ToolProviderError("Apple Maps found no route between these places.")
        let failed = try await call("directions", #"{"from":"Honolulu","to":"Tokyo"}"#)
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertEqual(text(failed), "Apple Maps found no route between these places.")
    }

    func testMapKitFailuresSayWhatWentWrong() {
        func message(_ code: MKError.Code, _ info: [String: Any] = [:]) -> String {
            MapKitService.failure(NSError(domain: MKErrorDomain, code: Int(code.rawValue), userInfo: info)).localizedDescription
        }
        XCTAssertEqual(message(.serverFailure, [NSLocalizedFailureReasonErrorKey: "Directions are not available between these locations."]),
                       "Directions are not available between these locations.")
        XCTAssertTrue(message(.serverFailure).hasPrefix("Apple Maps could not be reached"))
        XCTAssertEqual(message(.loadingThrottled), "Apple Maps is limiting requests from this Mac. Try again in a minute.")
    }
}
