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
    /// Budget per image. Binary search maximises quality within this limit.
    private static let maxImageBytes: Int = 4 * 1024 * 1024
    private static let thumbnailMaxDimension: CGFloat = 400
    private static let thumbnailSize = CGSize(width: 200, height: 200)  // kept for legacy callers
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
    /// Maximize JPEG quality within maxImageBytes budget.
    ///
    /// Strategy:
    /// 1. Try full original resolution first (no resize) — best quality
    /// 2. If over budget even at min quality, resize to maxImageDimension and retry
    /// 3. If still over budget, step down resolution by 25% per iteration until 1024px min
    /// Within each resolution tier, binary-search for the highest quality ≤ maxImageBytes.
    /// Returns a UIImage with scale=1.0 so .size == pixel dimensions.
    private static func progressiveCompress(_ image: UIImage) throws -> (UIImage, Data) {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let originalMaxPixel = max(pixelW, pixelH)

        // Resolution tiers to try, in order of preference (highest quality first)
        var tiers: [CGFloat] = []
        if originalMaxPixel <= maxImageDimension {
            tiers.append(originalMaxPixel)  // full res — no downscale
        }
        tiers.append(maxImageDimension)
        var tier = maxImageDimension * 0.75
        let minPixel: CGFloat = 1024
        while tier >= minPixel {
            tiers.append(tier.rounded())
            tier *= 0.75
        }
        tiers.append(minPixel)
        // Deduplicate while preserving order
        var seen = Set<CGFloat>()
        tiers = tiers.filter { seen.insert($0).inserted }

        for maxPixel in tiers {
            let resized = resizeToPixels(image, maxPixel: maxPixel)
            if let (quality, data) = binarySearchQuality(for: resized, budget: maxImageBytes) {
                let pw = Int(resized.size.width), ph = Int(resized.size.height)
                Log.debug("  → \(pw)×\(ph)px q=\(String(format: "%.2f", quality)) \(data.count/1024)KB",
                          category: "MediaOptimizer")
                return (resized, data)
            }
        }

        // Absolute fallback — min quality at min resolution
        let fallbackImg = resizeToPixels(image, maxPixel: minPixel)
        guard let fallback = fallbackImg.jpegData(compressionQuality: 0.35) else {
            throw MediaOptimizationError.conversionFailed
        }
        return (fallbackImg, fallback)
    }

    /// Binary search for the highest JPEG quality whose encoded size ≤ budget.
    /// Returns nil if even minQuality produces a file over budget.
    private static func binarySearchQuality(for image: UIImage, budget: Int) -> (CGFloat, Data)? {
        let minQ: CGFloat = 0.35
        let maxQ: CGFloat = 0.88    // cap at 0.88 — diminishing returns above this
        let tolerance: CGFloat = 0.03

        // Quick check: if high quality fits, return immediately
        if let data = image.jpegData(compressionQuality: maxQ), data.count <= budget {
            return (maxQ, data)
        }
        // Quick check: if even min quality is over budget, bail
        guard let minData = image.jpegData(compressionQuality: minQ),
              minData.count <= budget else {
            return nil
        }

        // Binary search between minQ and maxQ
        var lo = minQ, hi = maxQ
        var bestQ = minQ
        var bestData = minData

        while hi - lo > tolerance {
            let mid = (lo + hi) / 2
            if let data = image.jpegData(compressionQuality: mid), data.count <= budget {
                bestQ = mid
                bestData = data
                lo = mid
            } else {
                hi = mid
            }
        }
        return (bestQ, bestData)
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
