import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import Combine

/// A movie picked via `PhotosPicker` — imported to a stable temp file we own, because the
/// system-provided URL is short-lived. `MediaAttachment` reads bytes from this URL at send time.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

@MainActor
final class MessageInputAttachmentStore: ObservableObject {
    @Published private(set) var selectedAttachments: [MediaAttachment] = []
    @Published private(set) var selectedFileURLs: [URL] = []

    func appendDroppedImages(_ images: [PlatformImage]) {
        guard !images.isEmpty else { return }
        selectedAttachments.append(contentsOf: images.map { MediaAttachment(image: $0) })
    }

    func removeAttachment(at index: Int) {
        guard selectedAttachments.indices.contains(index) else { return }
        selectedAttachments.remove(at: index)
    }

    func removeFile(at index: Int) {
        guard selectedFileURLs.indices.contains(index) else { return }
        selectedFileURLs.remove(at: index)
    }

    func clear() {
        selectedAttachments.removeAll()
        selectedFileURLs.removeAll()
    }

    func canSend(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedAttachments.isEmpty
            || !selectedFileURLs.isEmpty
    }

    func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        selectedAttachments.removeAll()

        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo {
                if let attachment = await loadVideoAttachment(from: item) {
                    selectedAttachments.append(attachment)
                }
                continue
            }

            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = PlatformImage(data: data) else { continue }

            if Int64(data.count) > MessageSizeLimits.maxImageBytes {
                Log.error("Photo too large", category: "MessageInput")
                continue
            }

            let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            selectedAttachments.append(
                MediaAttachment(
                    originalData: data,
                    mimeType: mimeType,
                    displayImage: image
                )
            )
        }
    }

    /// Imports a picked video to a temp file and derives a poster frame + duration.
    /// The bytes stay on disk (not in memory) — the upload path transcodes from `videoURL`.
    private func loadVideoAttachment(from item: PhotosPickerItem) async -> MediaAttachment? {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            Log.error("Failed to load picked video", category: "MessageInput")
            return nil
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: movie.url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > MessageSizeLimits.maxVideoBytes {
            Log.error("Video too large (\(fileSize) bytes)", category: "MessageInput")
            try? FileManager.default.removeItem(at: movie.url)
            return nil
        }

        let asset = AVURLAsset(url: movie.url)
        let duration = (try? await asset.load(.duration))?.seconds
        // Poster must be non-nil: the preview bar maps attachments↔images by displayImage,
        // so a dropped poster would misalign remove-by-index. Fall back to a dark placeholder.
        let poster = (try? await MediaOptimizer.generateVideoThumbnail(from: movie.url))
            .flatMap { PlatformImage(data: $0) }
            ?? Self.videoPlaceholderPoster()

        return MediaAttachment(
            videoURL: movie.url,
            poster: poster,
            duration: duration
        )
    }

    private static func videoPlaceholderPoster() -> PlatformImage? {
        #if canImport(UIKit)
        let size = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        #else
        return nil
        #endif
    }

    func handlePickedFiles(_ urls: [URL]) {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp", "bmp", "tiff"]

        for url in urls {
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                loadImages(from: [url])
            } else {
                do {
                    try MessageValidator.validateFile(at: url)
                    selectedFileURLs.append(url)
                } catch let error as MessageValidationError {
                    ErrorRouter.shared.report(error)
                } catch {
                    ErrorRouter.shared.report(.unknown(error.userFacingMessage))
                }
            }
        }
    }

    private func loadImages(from urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url),
                  let image = PlatformImage(data: data) else { continue }

            if Int64(data.count) > MessageSizeLimits.maxImageBytes { continue }

            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            selectedAttachments.append(
                MediaAttachment(
                    originalData: data,
                    mimeType: mimeType,
                    displayImage: image
                )
            )
        }
    }
}
