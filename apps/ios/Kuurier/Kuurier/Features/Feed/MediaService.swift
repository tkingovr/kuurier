import Foundation
import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import Combine

/// Service for handling media selection, upload, and attachment
final class MediaService: ObservableObject {

    static let shared = MediaService()

    @Published var selectedItems: [SelectedMediaItem] = []
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0
    @Published var uploadError: String?

    private let api = APIClient.shared
    private let maxItems = 5
    private let maxFileSize: Int64 = 50 * 1024 * 1024 // 50MB

    private init() {}

    // MARK: - Selection Management

    var canAddMore: Bool {
        selectedItems.count < maxItems
    }

    var remainingSlots: Int {
        maxItems - selectedItems.count
    }

    func addItem(_ item: SelectedMediaItem) {
        guard canAddMore else { return }
        selectedItems.append(item)
    }

    func removeItem(at index: Int) {
        guard index < selectedItems.count else { return }
        selectedItems.remove(at: index)
    }

    func removeItem(id: UUID) {
        selectedItems.removeAll { $0.id == id }
    }

    func clearSelection() {
        selectedItems.removeAll()
        uploadProgress = 0
        uploadError = nil
    }

    // MARK: - Photo Picker Processing

    /// Processes PhotosPickerItem selections into SelectedMediaItems
    @MainActor
    func processPickerSelection(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard canAddMore else { break }

            // Try to load as image first
            if let data = try? await item.loadTransferable(type: Data.self) {
                if let uiImage = UIImage(data: data) {
                    // It's an image
                    let compressed = compressImage(uiImage)
                    let mediaItem = SelectedMediaItem(
                        data: compressed,
                        thumbnail: uiImage,
                        type: .image,
                        originalFilename: "photo.jpg"
                    )
                    addItem(mediaItem)
                } else {
                    // Might be a video - check supported types
                    if let supportedType = item.supportedContentTypes.first,
                       supportedType.conforms(to: .movie) {
                        // Load video
                        if let videoData = try? await loadVideoData(from: item) {
                            let thumbnail = await generateVideoThumbnail(from: videoData)
                            let mediaItem = SelectedMediaItem(
                                data: videoData,
                                thumbnail: thumbnail,
                                type: .video,
                                originalFilename: "video.mp4"
                            )
                            addItem(mediaItem)
                        }
                    }
                }
            }
        }
    }

    private func loadVideoData(from item: PhotosPickerItem) async throws -> Data? {
        if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
            return movie.data
        }
        return nil
    }

    private func compressImage(_ image: UIImage, maxSize: CGFloat = 1920) -> Data {
        var currentImage = image

        // Resize if needed
        let maxDimension = max(image.size.width, image.size.height)
        if maxDimension > maxSize {
            let scale = maxSize / maxDimension
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            if let resized = UIGraphicsGetImageFromCurrentImageContext() {
                currentImage = resized
            }
            UIGraphicsEndImageContext()
        }

        // Compress to JPEG with quality
        return currentImage.jpegData(compressionQuality: 0.8) ?? Data()
    }

    @MainActor
    private func generateVideoThumbnail(from data: Data) async -> UIImage? {
        // Write to temp file to generate thumbnail
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try? data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let asset = AVAsset(url: tempURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    // MARK: - Upload

    /// Uploads all selected media and attaches to a post
    /// - Parameter postId: The ID of the post to attach media to
    /// - Returns: Array of successfully attached media URLs
    @MainActor
    func uploadAndAttachMedia(to postId: String) async -> [String] {
        guard !selectedItems.isEmpty else { return [] }

        isUploading = true
        uploadError = nil
        uploadProgress = 0

        var uploadedUrls: [String] = []
        let totalItems = Double(selectedItems.count)

        for (index, item) in selectedItems.enumerated() {
            do {
                // Step 1: Upload file
                let uploadResponse: MediaUploadResponse = try await api.uploadMultipart(
                    "/media/upload",
                    fileData: item.data,
                    filename: item.originalFilename ?? "file",
                    mimeType: item.type.mimeType
                )

                // Step 2: Attach to post
                let attachRequest = MediaAttachRequest(
                    mediaUrl: uploadResponse.url,
                    mediaType: item.type.apiValue
                )

                let _: MediaAttachResponse = try await api.post(
                    "/media/attach/\(postId)",
                    body: attachRequest
                )

                uploadedUrls.append(uploadResponse.url)
                uploadProgress = Double(index + 1) / totalItems

            } catch {
                print("Failed to upload media item: \(error)")
                // Continue with other items even if one fails
                uploadError = "Some media failed to upload"
            }
        }

        isUploading = false
        return uploadedUrls
    }
}

// MARK: - Helper Types

private struct MediaAttachRequest: Encodable {
    let mediaUrl: String
    let mediaType: String

    enum CodingKeys: String, CodingKey {
        case mediaUrl = "media_url"
        case mediaType = "media_type"
    }
}

/// Transferable type for loading video data from PhotosPicker
struct VideoTransferable: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .movie) { data in
            VideoTransferable(data: data)
        }
    }
}
