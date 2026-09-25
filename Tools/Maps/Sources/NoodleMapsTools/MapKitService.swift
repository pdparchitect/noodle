import Foundation
import MapKit
import NoodleCore

/// Apple Maps through MapKit. It needs no entitlement beyond the App Sandbox: MapKit asks
/// the system's own maps service, which does the networking.
struct MapKitService: MapsService {
    func search(_ query: String, near: MapsLocation?, limit: Int) async throws -> [MapsPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near {
            let center = try await mapItem(near).location.coordinate
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 3_000, longitudinalMeters: 3_000)
            request.regionPriority = .required
        }
        do {
            return try await MKLocalSearch(request: request).start().mapItems.prefix(limit).map(place)
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            throw Self.failure(error)
        }
    }

    func geocode(_ location: MapsLocation) async throws -> [MapsPlace] {
        do {
            switch location {
            case let .coordinate(latitude, longitude):
                guard let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude)) else { return [] }
                return try await request.mapItems.map(place)
            case let .text(text):
                guard let request = MKGeocodingRequest(addressString: text) else { return [] }
                return try await request.mapItems.map(place)
            }
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            throw Self.failure(error)
        }
    }

    func directions(_ request: MapsDirectionsRequest) async throws -> [MapsRoute] {
        let source = try await mapItem(request.from), destination = try await mapItem(request.to)
        let directions = MKDirections.Request()
        directions.source = source; directions.destination = destination
        directions.transportType = switch request.mode {
        case .driving: .automobile
        case .walking: .walking
        case .cycling: .cycling
        case .transit: .transit
        }
        if let departure = request.departure { directions.departureDate = departure }
        if let arrival = request.arrival { directions.arrivalDate = arrival }
        directions.requestsAlternateRoutes = request.alternatives
        if request.avoidTolls { directions.tollPreference = .avoid }
        if request.avoidHighways { directions.highwayPreference = .avoid }
        let from = place(source), to = place(destination)
        do {
            // MapKit plans transit trips only as far as their times.
            if request.mode == .transit {
                let eta = try await MKDirections(request: directions).calculateETA()
                var route = MapsRoute(from: from, to: to, name: "", distance: eta.distance, duration: eta.expectedTravelTime)
                route.departure = eta.expectedDepartureDate; route.arrival = eta.expectedArrivalDate
                return [route]
            }
            return try await MKDirections(request: directions).calculate().routes.map { route in
                var result = MapsRoute(from: from, to: to, name: route.name, distance: route.distance, duration: route.expectedTravelTime,
                                       steps: route.steps.map { MapsStep(instruction: $0.instructions, distance: $0.distance) },
                                       advisories: route.advisoryNotices, hasTolls: route.hasTolls, hasHighways: route.hasHighways)
                if request.departure != nil || request.arrival != nil {
                    let departure = request.departure ?? request.arrival!.addingTimeInterval(-route.expectedTravelTime)
                    result.departure = departure; result.arrival = departure.addingTimeInterval(route.expectedTravelTime)
                }
                return result
            }
        } catch let error as MKError where error.code == .directionsNotFound {
            throw ToolProviderError("Apple Maps found no route \(request.mode.phrase) between these places.")
        } catch {
            throw Self.failure(error)
        }
    }

    private func mapItem(_ location: MapsLocation) async throws -> MKMapItem {
        switch location {
        case let .coordinate(latitude, longitude):
            return MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
        case let .text(text):
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            do {
                if let item = try await MKLocalSearch(request: request).start().mapItems.first { return item }
            } catch let error as MKError where error.code == .placemarkNotFound {
            } catch {
                throw Self.failure(error)
            }
            throw ToolProviderError("Apple Maps found no place for \(text).")
        }
    }

    private func place(_ item: MKMapItem) -> MapsPlace {
        let address = (item.address?.fullAddress ?? item.address?.shortAddress)?
            .split(whereSeparator: \.isNewline).joined(separator: ", ")
        let coordinate = item.location.coordinate
        return MapsPlace(name: item.name ?? address ?? MapsLocation.coordinate(coordinate.latitude, coordinate.longitude).query,
                         address: address, latitude: coordinate.latitude, longitude: coordinate.longitude,
                         category: item.pointOfInterestCategory.map { $0.rawValue.replacingOccurrences(of: "MKPOICategory", with: "") },
                         phone: item.phoneNumber, website: item.url)
    }

    static func failure(_ error: Error) -> Error {
        guard let error = error as? MKError else { return error }
        switch error.code {
        case .loadingThrottled: return ToolProviderError("Apple Maps is limiting requests from this Mac. Try again in a minute.")
        case .serverFailure, .unknown:
            // Maps reports an unreachable place as a server failure, with the reason attached.
            if let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String { return ToolProviderError(reason) }
            return ToolProviderError("Apple Maps could not be reached: \(error.localizedDescription)")
        default: return error
        }
    }
}
