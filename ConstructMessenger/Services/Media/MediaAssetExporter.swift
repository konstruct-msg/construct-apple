//
//  MediaAssetExporter.swift
//  Construct Messenger
//
//  PHAsset → MediaAttachment source material (image Data or temp video URL).
//  Export runs only on Send/Add — never while browsing the grid.
//

#if os(iOS)
import Foundation
import Photos
import AVFoundation
import UniformTypeIdentifiers
import UIKit

enum MediaAssetExportError: Error {
    case cancelled
    case noData
    case tooLarge
    case exportFailed(String)
}

enum MediaAssetExporter {

    /// Full-resolution image bytes + mime + display image for previews.
    static func exportImage(asset: PHAsset) async throws -> (data: Data, mimeType: String, display: PlatformImage?) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isSynchronous = false
        options.version = .current

        let (data, uti): (Data, String?) = try await withCheckedThrowingContinuation { cont in
            var finished = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                if finished { return }
                if let info, (info[PHImageCancelledKey] as? Bool) == true {
                    finished = true
                    cont.resume(throwing: MediaAssetExportError.cancelled)
                    return
                }
                if let err = info?[PHImageErrorKey] as? Error {
                    finished = true
                    cont.resume(throwing: MediaAssetExportError.exportFailed(err.localizedDescription))
                    return
                }
                // Prefer the final (non-degraded) callback when iCloud downloads.
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    return
                }
                guard let data else {
                    finished = true
                    cont.resume(throwing: MediaAssetExportError.noData)
                    return
                }
                finished = true
                cont.resume(returning: (data, uti))
            }
        }

        if Int64(data.count) > MessageSizeLimits.maxImageBytes {
            throw MediaAssetExportError.tooLarge
        }

        let mime = mimeType(forUTI: uti) ?? "image/jpeg"
        let display = PlatformImage(data: data)
        return (data, mime, display)
    }

    /// Copies/export the video into a temp file we own. Caller owns cleanup after send.
    static func exportVideo(asset: PHAsset) async throws -> (url: URL, poster: PlatformImage?, duration: TimeInterval?) {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let avAsset: AVAsset = try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { asset, _, info in
                if let info, (info[PHImageCancelledKey] as? Bool) == true {
                    cont.resume(throwing: MediaAssetExportError.cancelled)
                    return
                }
                if let err = info?[PHImageErrorKey] as? Error {
                    cont.resume(throwing: MediaAssetExportError.exportFailed(err.localizedDescription))
                    return
                }
                guard let asset else {
                    cont.resume(throwing: MediaAssetExportError.noData)
                    return
                }
                cont.resume(returning: asset)
            }
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: dest)

        if let urlAsset = avAsset as? AVURLAsset {
            // Prefer copy when the library hands us a file URL (fast path).
            do {
                try FileManager.default.copyItem(at: urlAsset.url, to: dest)
            } catch {
                // Some library URLs are not directly readable — fall through to export.
                try await exportAVAsset(avAsset, to: dest)
            }
        } else {
            try await exportAVAsset(avAsset, to: dest)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > MessageSizeLimits.maxVideoBytes {
            try? FileManager.default.removeItem(at: dest)
            throw MediaAssetExportError.tooLarge
        }

        let duration = try? await avAsset.load(.duration).seconds
        let posterData = try? await MediaOptimizer.generateVideoThumbnail(from: dest)
        let poster = posterData.flatMap { PlatformImage(data: $0) } ?? videoPlaceholderPoster()
        return (dest, poster, duration)
    }

    // MARK: - Helpers

    private static func exportAVAsset(_ avAsset: AVAsset, to dest: URL) async throws {
        guard let session = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaAssetExportError.exportFailed("export session")
        }
        do {
            try await session.export(to: dest, as: .mov)
        } catch is CancellationError {
            throw MediaAssetExportError.cancelled
        } catch {
            throw MediaAssetExportError.exportFailed(error.localizedDescription)
        }
    }

    private static func mimeType(forUTI uti: String?) -> String? {
        guard let uti, let type = UTType(uti) else { return nil }
        return type.preferredMIMEType
    }

    private static func videoPlaceholderPoster() -> PlatformImage? {
        let size = CGSize(width: 320, height: 320)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.12, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
#endif
