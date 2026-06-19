import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Combine

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
