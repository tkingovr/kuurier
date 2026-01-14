import Foundation
import Combine

/// Service for managing events
final class EventsService: ObservableObject {

    static let shared = EventsService()

    @Published var events: [Event] = []
    @Published var isLoading = false
    @Published var isCreating = false
    @Published var error: String?

    private let api = APIClient.shared

    private init() {}

    // MARK: - Fetch Events

    /// Fetches upcoming events with optional filters
    @MainActor
    func fetchEvents(type: EventType? = nil, refresh: Bool = false) async {
        guard !isLoading || refresh else { return }

        isLoading = true
        error = nil

        do {
            var queryItems: [URLQueryItem] = []
            if let type = type {
                queryItems.append(URLQueryItem(name: "type", value: type.rawValue))
            }

            let response: EventsResponse = try await api.get("/events", queryItems: queryItems)
            events = response.events
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Get Single Event

    /// Fetches a single event by ID
    @MainActor
    func getEvent(id: String) async -> Event? {
        do {
            let event: Event = try await api.get("/events/\(id)")
            return event
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Create Event

    /// Creates a new event
    @MainActor
    func createEvent(
        title: String,
        description: String?,
        eventType: EventType,
        latitude: Double,
        longitude: Double,
        locationName: String?,
        locationArea: String?,
        locationVisibility: LocationVisibility,
        locationRevealAt: Date?,
        startsAt: Date,
        endsAt: Date?
    ) async -> Bool {
        guard !isCreating else { return false }

        isCreating = true
        error = nil

        do {
            let request = CreateEventRequest(
                title: title,
                description: description?.isEmpty == true ? nil : description,
                eventType: eventType.rawValue,
                latitude: latitude,
                longitude: longitude,
                locationName: locationName?.isEmpty == true ? nil : locationName,
                locationArea: locationArea?.isEmpty == true ? nil : locationArea,
                locationVisibility: locationVisibility.rawValue,
                locationRevealAt: locationRevealAt.map { Int($0.timeIntervalSince1970) },
                startsAt: Int(startsAt.timeIntervalSince1970),
                endsAt: endsAt.map { Int($0.timeIntervalSince1970) }
            )

            let _: CreateEventResponse = try await api.post("/events", body: request)

            isCreating = false

            // Refresh events list
            await fetchEvents(refresh: true)
            return true
        } catch {
            self.error = error.localizedDescription
            isCreating = false
            return false
        }
    }

    // MARK: - Update Event

    /// Updates an existing event (organizer only)
    @MainActor
    func updateEvent(
        id: String,
        title: String? = nil,
        description: String? = nil,
        locationName: String? = nil,
        locationArea: String? = nil,
        locationVisibility: LocationVisibility? = nil,
        locationRevealAt: Date? = nil,
        isCancelled: Bool? = nil
    ) async -> Bool {
        do {
            let request = UpdateEventRequest(
                title: title,
                description: description,
                locationName: locationName,
                locationArea: locationArea,
                locationVisibility: locationVisibility?.rawValue,
                locationRevealAt: locationRevealAt.map { Int($0.timeIntervalSince1970) },
                isCancelled: isCancelled
            )

            let _: MessageResponse = try await api.put("/events/\(id)", body: request)
            await fetchEvents(refresh: true)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Delete Event

    /// Deletes an event (organizer only)
    @MainActor
    func deleteEvent(id: String) async -> Bool {
        do {
            let _: MessageResponse = try await api.delete("/events/\(id)")
            events.removeAll { $0.id == id }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - RSVP

    /// RSVPs to an event
    @MainActor
    func rsvp(eventId: String, status: RSVPStatus) async -> RSVPResponse? {
        do {
            let request = RSVPRequest(status: status.rawValue)
            let response: RSVPResponse = try await api.post("/events/\(eventId)/rsvp", body: request)

            // Update local event if we have it
            if let index = events.firstIndex(where: { $0.id == eventId }) {
                // Refresh to get updated RSVP count and potentially revealed location
                if let updated = await getEvent(id: eventId) {
                    events[index] = updated
                }
            }

            return response
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Cancels RSVP for an event
    @MainActor
    func cancelRSVP(eventId: String) async -> Bool {
        do {
            let _: MessageResponse = try await api.delete("/events/\(eventId)/rsvp")

            // Refresh to update local state
            if let index = events.firstIndex(where: { $0.id == eventId }),
               let updated = await getEvent(id: eventId) {
                events[index] = updated
            }

            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Nearby Events

    /// Fetches events near a location (public events only)
    @MainActor
    func fetchNearbyEvents(latitude: Double, longitude: Double, radiusMeters: Int = 10000) async -> [Event] {
        do {
            let response: NearbyEventsResponse = try await api.get("/events/nearby", queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(name: "radius", value: String(radiusMeters))
            ])
            return response.events
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    // MARK: - Public Events for Map

    /// Fetches public events for map display
    @MainActor
    func fetchPublicEventsForMap(minLat: Double? = nil, maxLat: Double? = nil, minLon: Double? = nil, maxLon: Double? = nil) async -> [Event] {
        do {
            var queryItems: [URLQueryItem] = []
            if let minLat = minLat { queryItems.append(URLQueryItem(name: "min_lat", value: String(minLat))) }
            if let maxLat = maxLat { queryItems.append(URLQueryItem(name: "max_lat", value: String(maxLat))) }
            if let minLon = minLon { queryItems.append(URLQueryItem(name: "min_lon", value: String(minLon))) }
            if let maxLon = maxLon { queryItems.append(URLQueryItem(name: "max_lon", value: String(maxLon))) }

            let response: PublicEventsResponse = try await api.get("/events/map", queryItems: queryItems)
            return response.events
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }
}

// MARK: - Request Types

private struct CreateEventRequest: Encodable {
    let title: String
    let description: String?
    let eventType: String
    let latitude: Double
    let longitude: Double
    let locationName: String?
    let locationArea: String?
    let locationVisibility: String
    let locationRevealAt: Int?
    let startsAt: Int
    let endsAt: Int?
}

private struct UpdateEventRequest: Encodable {
    let title: String?
    let description: String?
    let locationName: String?
    let locationArea: String?
    let locationVisibility: String?
    let locationRevealAt: Int?
    let isCancelled: Bool?
}

private struct RSVPRequest: Encodable {
    let status: String
}

// MARK: - Response Types

private struct CreateEventResponse: Decodable {
    let id: String
    let message: String
}

struct RSVPResponse: Decodable {
    let message: String
    let status: String
    let location: Location?
    let locationName: String?
    let locationRevealed: Bool?
    let channelId: String?
    let joinedChannel: Bool?

    enum CodingKeys: String, CodingKey {
        case message
        case status
        case location
        case locationName = "location_name"
        case locationRevealed = "location_revealed"
        case channelId = "channel_id"
        case joinedChannel = "joined_channel"
    }
}

private struct PublicEventsResponse: Decodable {
    let events: [Event]
}
