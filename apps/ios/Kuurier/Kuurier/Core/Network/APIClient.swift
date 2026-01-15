import Foundation
import CryptoKit
import Security

/// Secure API client with certificate pinning and automatic token refresh
final class APIClient: NSObject, URLSessionDelegate {

    static let shared = APIClient()

    private var _session: URLSession?
    private var session: URLSession {
        if let existing = _session {
            return existing
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.apiRequestTimeout
        config.timeoutIntervalForResource = AppConfig.apiResourceTimeout
        config.waitsForConnectivity = true

        let newSession: URLSession
        if AppConfig.enableCertificatePinning {
            newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        } else {
            newSession = URLSession(configuration: config)
        }

        _session = newSession
        return newSession
    }

    let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private override init() {
        self.baseURL = AppConfig.apiBaseURL

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()

        super.init()

        // Configure decoder
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try ISO8601 with fractional seconds (Go's default format)
            let iso8601WithFractional = ISO8601DateFormatter()
            iso8601WithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso8601WithFractional.date(from: dateString) {
                return date
            }

            // Fallback to standard ISO8601
            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime]
            if let date = iso8601.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }

        // Configure encoder
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - Certificate Pinning

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let serverCertificate = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Only pin for configured hosts
        guard AppConfig.pinnedHosts.contains(host) else {
            // Allow other hosts without pinning
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Extract public key from certificate
        guard let serverPublicKey = SecCertificateCopyKey(serverCertificate),
              let serverPublicKeyData = SecKeyCopyExternalRepresentation(serverPublicKey, nil) as Data? else {
            if AppConfig.enableDebugLogging {
                print("[CertPinning] Failed to extract public key from certificate")
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Hash the public key (SPKI)
        let serverKeyHash = sha256Hash(of: serverPublicKeyData)

        // Check if the hash matches any of our pinned keys
        let isPinned = AppConfig.pinnedPublicKeyHashes.contains(serverKeyHash)

        if isPinned {
            // Certificate is pinned - allow the connection
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)

            if AppConfig.enableDebugLogging {
                print("[CertPinning] Certificate validated for host: \(host)")
            }
        } else {
            // Certificate not pinned - reject the connection
            if AppConfig.enableDebugLogging {
                print("[CertPinning] Certificate pinning failed for host: \(host)")
                print("[CertPinning] Server key hash: \(serverKeyHash)")
                print("[CertPinning] Expected one of: \(AppConfig.pinnedPublicKeyHashes)")
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Computes SHA256 hash of data and returns base64-encoded string
    private func sha256Hash(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
    }

    // MARK: - Request Methods

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        let request = try buildRequest(path: path, method: "GET", queryItems: queryItems)
        return try await execute(request)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = try buildRequest(path: path, method: "POST")
        request.httpBody = try encoder.encode(body)
        return try await execute(request)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = try buildRequest(path: path, method: "PUT")
        request.httpBody = try encoder.encode(body)
        return try await execute(request)
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        let request = try buildRequest(path: path, method: "DELETE")
        return try await execute(request)
    }

    // MARK: - Multipart Upload

    /// Uploads a file using multipart/form-data
    func uploadMultipart<T: Decodable>(
        _ path: String,
        fileData: Data,
        filename: String,
        mimeType: String,
        fieldName: String = "file"
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = try buildRequest(path: path, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // File part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // Closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        return try await execute(request)
    }

    // MARK: - Request Building

    private func buildRequest(path: String, method: String, queryItems: [URLQueryItem]? = nil) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
        components.queryItems = queryItems

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add auth token if available
        if let token = SecureStorage.shared.authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    // MARK: - Request Execution

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as NSError {
            // Check for certificate pinning failure
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                throw APIError.certificatePinningFailed
            }
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Handle different status codes
        switch httpResponse.statusCode {
        case 200...299:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decodingFailed(error)
            }

        case 401:
            // Token expired or invalid
            SecureStorage.shared.authToken = nil
            throw APIError.unauthorized

        case 403:
            throw APIError.forbidden(parseErrorMessage(from: data))

        case 404:
            throw APIError.notFound

        case 429:
            throw APIError.rateLimited

        case 500...599:
            throw APIError.serverError(httpResponse.statusCode)

        default:
            throw APIError.httpError(httpResponse.statusCode, parseErrorMessage(from: data))
        }
    }

    private func parseErrorMessage(from data: Data) -> String {
        struct ErrorResponse: Decodable {
            let error: String?
            let message: String?
        }

        if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
            return errorResponse.error ?? errorResponse.message ?? "Unknown error"
        }

        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}

// MARK: - API Errors

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden(String)
    case notFound
    case rateLimited
    case serverError(Int)
    case httpError(Int, String)
    case decodingFailed(Error)
    case networkError(Error)
    case certificatePinningFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "Please log in again"
        case .forbidden(let message):
            return message
        case .notFound:
            return "Resource not found"
        case .rateLimited:
            return "Too many requests. Please wait a moment."
        case .serverError(let code):
            return "Server error (\(code))"
        case .httpError(let code, let message):
            return "Error \(code): \(message)"
        case .decodingFailed(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .certificatePinningFailed:
            return "Security error: Unable to verify server identity"
        }
    }
}
