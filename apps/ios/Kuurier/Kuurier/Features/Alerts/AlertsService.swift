import Foundation
import Combine
import CoreLocation

/// Service for managing SOS alerts
final class AlertsService: ObservableObject {

    static let shared = AlertsService()

    @Published var alerts: [Alert] = []
    @Published var nearbyAlerts: [Alert] = []
    @Published var isLoading = false
    @Published var isCreating = false
    @Published var error: String?

    private let api = APIClient.shared
    private let locationManager = CLLocationManager()

    private init() {}

    // MARK: - Fetch Alerts

    /// Fetches active alerts
    @MainActor
    func fetchAlerts(status: String = "active", refresh: Bool = false) async {
        guard !isLoading || refresh else { return }

        isLoading = true
        error = nil

        do {
            let response: AlertsResponse = try await api.get("/alerts", queryItems: [
                URLQueryItem(name: "status", value: status),
                URLQueryItem(name: "limit", value: "50")
            ])
            alerts = response.alerts
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Fetch Nearby Alerts

    /// Fetches active alerts near a location
    @MainActor
    func fetchNearbyAlerts(latitude: Double, longitude: Double) async {
        do {
            let response: NearbyAlertsResponse = try await api.get("/alerts/nearby", queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude))
            ])
            nearbyAlerts = response.alerts
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fetches nearby alerts using current device location
    @MainActor
    func fetchNearbyAlertsFromCurrentLocation() async {
        guard let location = locationManager.location else {
            // Request location if not available
            locationManager.requestWhenInUseAuthorization()
            return
        }

        await fetchNearbyAlerts(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    // MARK: - Get Single Alert

    /// Fetches a single alert by ID with responses
    @MainActor
    func getAlert(id: String) async -> Alert? {
        do {
            let alert: Alert = try await api.get("/alerts/\(id)")
            return alert
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Create Alert

    /// Creates a new SOS alert
    @MainActor
    func createAlert(
        title: String,
        description: String?,
        severity: Int,
        latitude: Double,
        longitude: Double,
        locationName: String?,
        radiusMeters: Int = 5000
    ) async -> CreateAlertResponse? {
        guard !isCreating else { return nil }

        isCreating = true
        error = nil

        do {
            let request = CreateAlertRequest(
                title: title,
                description: description?.isEmpty == true ? nil : description,
                severity: severity,
                latitude: latitude,
                longitude: longitude,
                locationName: locationName?.isEmpty == true ? nil : locationName,
                radiusMeters: radiusMeters
            )

            let response: CreateAlertResponse = try await api.post("/alerts", body: request)

            isCreating = false

            // Refresh alerts list
            await fetchAlerts(refresh: true)
            return response
        } catch let apiError as APIError {
            self.error = apiError.localizedDescription
            isCreating = false
            return nil
        } catch {
            self.error = error.localizedDescription
            isCreating = false
            return nil
        }
    }

    /// Creates alert using current device location
    @MainActor
    func createAlertAtCurrentLocation(
        title: String,
        description: String?,
        severity: Int,
        radiusMeters: Int = 5000
    ) async -> CreateAlertResponse? {
        guard let location = locationManager.location else {
            self.error = "Unable to get current location"
            return nil
        }

        return await createAlert(
            title: title,
            description: description,
            severity: severity,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            locationName: nil,
            radiusMeters: radiusMeters
        )
    }

    // MARK: - Update Alert Status

    /// Updates the status of an alert (author only)
    @MainActor
    func updateAlertStatus(alertId: String, status: AlertStatus) async -> Bool {
        do {
            let request = UpdateAlertStatusRequest(status: status.rawValue)
            let _: MessageResponse = try await api.put("/alerts/\(alertId)/status", body: request)

            // Update local alert if we have it
            if let index = alerts.firstIndex(where: { $0.id == alertId }) {
                // Refresh to get updated data
                if let updated = await getAlert(id: alertId) {
                    alerts[index] = updated
                }
            }

            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Respond to Alert

    /// Responds to an alert
    @MainActor
    func respondToAlert(
        alertId: String,
        status: AlertResponseStatus,
        etaMinutes: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) async -> Bool {
        do {
            let request = RespondToAlertRequest(
                status: status.rawValue,
                etaMinutes: etaMinutes,
                latitude: latitude,
                longitude: longitude
            )

            let _: MessageResponse = try await api.post("/alerts/\(alertId)/respond", body: request)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Responds to alert with current location
    @MainActor
    func respondToAlertWithLocation(
        alertId: String,
        status: AlertResponseStatus,
        etaMinutes: Int? = nil
    ) async -> Bool {
        let location = locationManager.location

        return await respondToAlert(
            alertId: alertId,
            status: status,
            etaMinutes: etaMinutes,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude
        )
    }
}

// MARK: - Request Types

private struct CreateAlertRequest: Encodable {
    let title: String
    let description: String?
    let severity: Int
    let latitude: Double
    let longitude: Double
    let locationName: String?
    let radiusMeters: Int

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case severity
        case latitude
        case longitude
        case locationName = "location_name"
        case radiusMeters = "radius_meters"
    }
}

private struct UpdateAlertStatusRequest: Encodable {
    let status: String
}

private struct RespondToAlertRequest: Encodable {
    let status: String
    let etaMinutes: Int?
    let latitude: Double?
    let longitude: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case etaMinutes = "eta_minutes"
        case latitude
        case longitude
    }
}

// MARK: - Response Types

struct CreateAlertResponse: Decodable {
    let id: String
    let message: String
}
