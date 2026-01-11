import Foundation
import Combine
import CoreLocation

/// Service for fetching map/geo data from the API
final class MapService: ObservableObject {

    static let shared = MapService()

    @Published var markers: [MapMarker] = []
    @Published var isLoading = false
    @Published var error: String?

    private let api = APIClient.shared
    private var lastFetchedRegion: MapRegion?

    private init() {}

    // MARK: - Fetch Clusters/Posts

    /// Fetches markers (clusters or individual posts) for the visible map region
    @MainActor
    func fetchMarkers(region: MapRegion, zoom: Int) async {
        // Avoid refetching if region hasn't changed significantly
        if let last = lastFetchedRegion, last.isClose(to: region) {
            return
        }

        isLoading = true
        error = nil

        do {
            let response: ClustersResponse = try await api.get("/map/clusters", queryItems: [
                URLQueryItem(name: "min_lat", value: String(region.minLat)),
                URLQueryItem(name: "max_lat", value: String(region.maxLat)),
                URLQueryItem(name: "min_lon", value: String(region.minLon)),
                URLQueryItem(name: "max_lon", value: String(region.maxLon)),
                URLQueryItem(name: "zoom", value: String(zoom))
            ])

            // Convert MapCluster to MapMarker
            markers = response.markers.map { MapMarker(from: $0) }
            lastFetchedRegion = region
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Fetch Nearby Posts

    /// Fetches posts near a specific location
    @MainActor
    func fetchNearby(latitude: Double, longitude: Double, radiusMeters: Int = 5000) async -> [Post] {
        do {
            let response: NearbyPostsResponse = try await api.get("/map/nearby", queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(name: "radius", value: String(radiusMeters))
            ])
            return response.posts
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    // MARK: - Fetch Heatmap

    /// Fetches heatmap data for the visible region
    @MainActor
    func fetchHeatmap(region: MapRegion, gridSize: Double = 1.0) async -> [HeatmapCell] {
        do {
            let response: HeatmapResponse = try await api.get("/map/heatmap", queryItems: [
                URLQueryItem(name: "min_lat", value: String(region.minLat)),
                URLQueryItem(name: "max_lat", value: String(region.maxLat)),
                URLQueryItem(name: "min_lon", value: String(region.minLon)),
                URLQueryItem(name: "max_lon", value: String(region.maxLon)),
                URLQueryItem(name: "grid_size", value: String(gridSize))
            ])
            return response.cells
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    /// Clears cached data
    func clearCache() {
        lastFetchedRegion = nil
        markers = []
    }
}

// MARK: - Map Region (for viewport tracking)

struct MapRegion: Equatable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    var centerLat: Double { (minLat + maxLat) / 2 }
    var centerLon: Double { (minLon + maxLon) / 2 }

    func isClose(to other: MapRegion, threshold: Double = 0.01) -> Bool {
        abs(minLat - other.minLat) < threshold &&
        abs(maxLat - other.maxLat) < threshold &&
        abs(minLon - other.minLon) < threshold &&
        abs(maxLon - other.maxLon) < threshold
    }
}

// MARK: - Map Marker (for SwiftUI Map display)

struct MapMarker: Identifiable {
    let id: String
    let type: MarkerType
    let latitude: Double
    let longitude: Double
    let count: Int?
    let maxUrgency: Int?
    let content: String?
    let sourceType: String?
    let createdAt: Date?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    enum MarkerType {
        case post
        case cluster
    }

    /// Initialize from MapCluster (API response model)
    init(from cluster: MapCluster) {
        self.id = cluster.id ?? "cluster-\(cluster.latitude)-\(cluster.longitude)"
        self.type = cluster.type == "cluster" ? .cluster : .post
        self.latitude = cluster.latitude
        self.longitude = cluster.longitude
        self.count = cluster.count
        self.maxUrgency = cluster.maxUrgency
        self.content = cluster.content
        self.sourceType = cluster.sourceType
        self.createdAt = cluster.createdAt
    }
}
