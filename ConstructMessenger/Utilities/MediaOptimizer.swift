//
//  MediaOptimizer.swift
//  Construct Messenger
//
//  Optimizes media files before encryption.
//  UIKit-specific rendering is guarded with #if canImport(UIKit);
//  macOS uses AppKit/NSBitmapImageRep equivalents.
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Media Optimization Error
enum MediaOptimizationError: LocalizedError {
    case invalidImage, conversionFailed, thumbnailGenerationFailed, unsupportedFormat
    var errorDescription: String? {
        switch self {
        case .invalidImage:              return "Invalid or corrupted image"
        case .conversionFailed:          return "Failed to convert image format"
        case .thumbnailGenerationFailed: return "Failed to generate thumbnail"
        case .unsupportedFormat:         return "Unsupported media format"
        }
    }
}

// MARK: - Optimized Media
struct OptimizedMedia {
    let data: Data
    let thumbnail: Data?
    let metadata: MediaMetadata
}

// MARK: - Media Metadata
struct MediaMetadata {
    let originalSize: Int
    let optimizedSize: Int
    let width: Int?
    let height: Int?
    let duration: TimeInterval?
    let mimeType: String
}

// MARK: - Media Optimizer
struct MediaOptimizer {

    /// Max pixel dimension on the longest side. 1920px is a good chat quality/size balance.
    private static let maxImageDimension: CGFloat = 1920
    /// 4 MB per image — generous headroom for high-res photos after proper pixel-space compress
    private static let maxImageBytes: Int = 4 * 1024 * 1024
    private static let thumbnailMaxDimension: CGFloat = 400
    private static let thumbnailSize = CGSize(width: 200, height: 200)  // kept for legacy callers
    /// Start at 0.80 — avoids inflating already-compressed JPEGs while keeping good quality
    private static let jpegQualitySteps: [CGFloat] = [0.80, 0.70, 0.60, 0.50, 0.40]
    private static let thumbnailQuality: CGFloat = 0.70

    static func optimizeImage(_ image: PlatformImage) throws -> OptimizedMedia {
        #if canImport(UIKit)
        let (optimizedImage, optimizedData) = try progressiveCompress(image)
        let thumbnail = try generateThumbnail(from: optimizedImage)
        // After compress, optimizedImage has scale=1.0, so .size == pixel dimensions
        let pw = Int(optimizedImage.size.width), ph = Int(optimizedImage.size.height)
        let metadata = MediaMetadata(
            originalSize: optimizedData.count, optimizedSize: optimizedData.count,
            width: pw, height: ph,
            duration: nil, mimeType: "image/jpeg"
        )
        Log.info("Image optimized → \(optimizedData.count) bytes (\(pw)×\(ph)px)", category: "MediaOptimizer")
        return OptimizedMedia(data: optimizedData, thumbnail: thumbnail, metadata: metadata)
        #else
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: Double(0.8))]) else {
            throw MediaOptimizationError.conversionFailed
        }
        let metadata = MediaMetadata(
            originalSize: tiff.count, optimizedSize: data.count,
            width: Int(image.size.width), height: Int(image.size.height),
            duration: nil, mimeType: "image/jpeg"
        )
        return OptimizedMedia(data: data, thumbnail: nil, metadata: metadata)
        #endif
    }

    static func optimizeAvatar(_ image: PlatformImage) throws -> Data {
        #if canImport(UIKit)
        let targetSize: CGFloat = 512
        let size = image.size
        let scale = max(targetSize / size.width, targetSize / size.height)
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
        let (cropX, cropY) = ((scaledSize.width - targetSize) / 2, (scaledSize.height - targetSize) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: targetSize, height: targetSize), format: format)
        let cropped = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: CGSize(width: targetSize, height: targetSize)))
            image.draw(in: CGRect(x: -cropX, y: -cropY, width: scaledSize.width, height: scaledSize.height))
        }
        guard let data = cropped.jpegData(compressionQuality: 0.8) else { throw MediaOptimizationError.conversionFailed }
        Log.info("Avatar optimized: \(data.count) bytes (512×512)", category: "MediaOptimizer")
        return data
        #else
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: Double(0.8))]) else {
            throw MediaOptimizationError.conversionFailed
        }
        return data
        #endif
    }

    static func optimizeImage(from url: URL) throws -> OptimizedMedia {
        guard let image = PlatformImage(contentsOfFile: url.path) else { throw MediaOptimizationError.invalidImage }
        return try optimizeImage(image)
    }

    static func generateThumbnail(from image: PlatformImage) throws -> Data {
        #if canImport(UIKit)
        // Work in pixel space (scale=1.0 throughout)
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let scale = thumbnailMaxDimension / max(pixelW, pixelH)
        let targetPixels = CGSize(width: pixelW * scale, height: pixelH * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetPixels, format: format)
        let thumb = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: targetPixels)) }
        guard let data = thumb.jpegData(compressionQuality: thumbnailQuality) else {
            throw MediaOptimizationError.thumbnailGenerationFailed
        }
        return data
        #else
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: Double(thumbnailQuality))]) else {
            throw MediaOptimizationError.thumbnailGenerationFailed
        }
        return data
        #endif
    }

    static func generateVideoThumbnail(from url: URL) async throws -> Data {
        #if canImport(UIKit)
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 60)
        return try await withCheckedThrowingContinuation { continuation in
            imageGenerator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                guard error == nil, let cgImage else {
                    continuation.resume(throwing: MediaOptimizationError.thumbnailGenerationFailed); return
                }
                do {
                    continuation.resume(returning: try generateThumbnail(from: UIImage(cgImage: cgImage)))
                } catch {
                    continuation.resume(throwing: MediaOptimizationError.thumbnailGenerationFailed)
                }
            }
        }
        #else
        throw MediaOptimizationError.unsupportedFormat
        #endif
    }

    static func optimizeVideo(from url: URL) async throws -> OptimizedMedia {
        let videoData = try Data(contentsOf: url)
        let thumbnail = try await generateVideoThumbnail(from: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.load(.tracks)
        let videoTrack = tracks.first(where: { $0.mediaType == .video })
        let size = try await videoTrack?.load(.naturalSize)
        let metadata = MediaMetadata(
            originalSize: videoData.count, optimizedSize: videoData.count,
            width: size.map { Int($0.width) }, height: size.map { Int($0.height) },
            duration: duration, mimeType: "video/mp4"
        )
        return OptimizedMedia(data: videoData, thumbnail: thumbnail, metadata: metadata)
    }

    // MARK: - Private (iOS only)

    #if canImport(UIKit)
    /// Compress to ≤ maxImageBytes, working entirely in pixel space (scale=1.0).
    /// Returns a UIImage with scale=1.0 so .size == pixel dimensions.
    private static func progressiveCompress(_ image: UIImage) throws -> (UIImage, Data) {
        // Convert image to pixel-space dimensions
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale

        var targetMaxPixel = maxImageDimension
        let minPixel: CGFloat = 1024
        while true {
            let resized = resizeToPixels(image, maxPixel: targetMaxPixel)
            for quality in jpegQualitySteps {
                if let data = resized.jpegData(compressionQuality: quality),
                   data.count <= maxImageBytes {
                    return (resized, data)
                }
            }
            if targetMaxPixel <= minPixel {
                guard let fallback = resized.jpegData(compressionQuality: jpegQualitySteps.last ?? 0.35) else {
                    throw MediaOptimizationError.conversionFailed
                }
                return (resized, fallback)
            }
            targetMaxPixel = max(minPixel, targetMaxPixel * 0.75)
        }
        // unreachable but needed for compiler
        _ = (pixelW, pixelH)
    }

    /// Downscale to fit within maxPixel on the longest side.
    /// Always renders at scale=1.0 so the returned UIImage.size equals its pixel dimensions.
    private static func resizeToPixels(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        guard pixelW > maxPixel || pixelH > maxPixel else {
            // Already fits — return 1x copy so all callers work in pixel space
            if image.scale == 1.0 { return image }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: pixelW, height: pixelH), format: format)
            return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: CGSize(width: pixelW, height: pixelH))) }
        }
        let ratio = pixelW / pixelH
        let newSize: CGSize = pixelW > pixelH
            ? CGSize(width: maxPixel, height: (maxPixel / ratio).rounded())
            : CGSize(width: (maxPixel * ratio).rounded(), height: maxPixel)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0      // CRITICAL: produce 1x output regardless of device scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
    #endif
}

// MARK: - UIImage resize helper (iOS only)
#if canImport(UIKit)
extension UIImage {
    func resized(to targetSize: CGSize, contentMode: UIView.ContentMode = .scaleAspectFit) -> UIImage {
        let size = self.size
        let wRatio = targetSize.width / size.width, hRatio = targetSize.height / size.height
        let ratio = contentMode == .scaleAspectFit ? min(wRatio, hRatio) : max(wRatio, hRatio)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        // Always render at scale=1.0 so the returned image.size equals pixel dimensions
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
#endif
