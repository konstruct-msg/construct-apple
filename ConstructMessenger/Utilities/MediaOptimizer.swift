//
//  MediaOptimizer.swift
//  Construct Messenger
//
//  Optimizes media files before encryption
//  - Images: resize, convert, compress, strip EXIF
//  - Thumbnails: generate 200x200 previews
//

import Foundation
import UIKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Media Optimization Error
enum MediaOptimizationError: LocalizedError {
    case invalidImage
    case conversionFailed
    case thumbnailGenerationFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Invalid or corrupted image"
        case .conversionFailed:
            return "Failed to convert image format"
        case .thumbnailGenerationFailed:
            return "Failed to generate thumbnail"
        case .unsupportedFormat:
            return "Unsupported media format"
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
    let duration: TimeInterval?  // For video/audio
    let mimeType: String
}

// MARK: - Media Optimizer
struct MediaOptimizer {

    // MARK: - Constants

    /// Max image dimension (2048px for long side)
    private static let maxImageDimension: CGFloat = 2048
    
    /// Max image file size (5 MB)
    private static let maxImageBytes: Int = 5 * 1024 * 1024

    /// Thumbnail size (200x200)
    private static let thumbnailSize = CGSize(width: 200, height: 200)

    /// JPEG compression quality steps (highest to lowest)
    private static let jpegQualitySteps: [CGFloat] = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4]

    /// Thumbnail JPEG quality (0.7 = 70%, smaller for network)
    private static let thumbnailQuality: CGFloat = 0.7

    // MARK: - Image Optimization

    /// Optimizes an image for upload
    /// - Parameter image: Original UIImage
    /// - Returns: OptimizedMedia with data, thumbnail, and metadata
    /// - Throws: MediaOptimizationError if optimization fails
    static func optimizeImage(_ image: UIImage) throws -> OptimizedMedia {
        let originalData = image.pngData() ?? Data()
        let originalSize = originalData.count

        // 1. Progressive resize + compression to fit size budget
        let (optimizedImage, optimizedData) = try progressiveCompress(image)

        // 2. Generate thumbnail
        let thumbnail = try generateThumbnail(from: optimizedImage)

        // 3. Extract metadata
        let metadata = MediaMetadata(
            originalSize: originalSize,
            optimizedSize: optimizedData.count,
            width: Int(optimizedImage.size.width),
            height: Int(optimizedImage.size.height),
            duration: nil,
            mimeType: "image/jpeg"
        )

        Log.info("Image optimized: \(originalSize) → \(optimizedData.count) bytes (\(compressionRatio(original: originalSize, optimized: optimizedData.count))% reduction)", category: "MediaOptimizer")

        return OptimizedMedia(
            data: optimizedData,
            thumbnail: thumbnail,
            metadata: metadata
        )
    }

    // MARK: - Progressive Compression

    /// Progressive compression to fit max size without unnecessary quality loss
    private static func progressiveCompress(_ image: UIImage) throws -> (UIImage, Data) {
        var targetDimension = maxImageDimension
        let minDimension: CGFloat = 1024

        while true {
            let resizedImage = resizeImage(image, maxDimension: targetDimension)

            for quality in jpegQualitySteps {
                if let data = resizedImage.jpegData(compressionQuality: quality),
                   data.count <= maxImageBytes {
                    return (resizedImage, data)
                }
            }

            // If still too large, reduce dimension and retry
            if targetDimension <= minDimension {
                // Return best effort at lowest quality
                guard let fallback = resizedImage.jpegData(compressionQuality: jpegQualitySteps.last ?? 0.4) else {
                    throw MediaOptimizationError.conversionFailed
                }
                return (resizedImage, fallback)
            }

            targetDimension = max(minDimension, targetDimension * 0.8)
        }
    }

    /// Optimizes an image for use as avatar (512×512 square crop, JPEG 0.8)
    /// No artificial size cap — uploaded via gRPC media service (not WebSocket)
    static func optimizeAvatar(_ image: UIImage) throws -> Data {
        let targetSize: CGFloat = 512
        let size = image.size
        let scale = max(targetSize / size.width, targetSize / size.height)
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
        let cropX = (scaledSize.width - targetSize) / 2
        let cropY = (scaledSize.height - targetSize) / 2

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: targetSize, height: targetSize),
            format: format
        )
        let cropped = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: CGSize(width: targetSize, height: targetSize)))
            image.draw(in: CGRect(x: -cropX, y: -cropY, width: scaledSize.width, height: scaledSize.height))
        }

        guard let data = cropped.jpegData(compressionQuality: 0.8) else {
            throw MediaOptimizationError.conversionFailed
        }
        Log.info("Avatar optimized: \(data.count) bytes (512×512)", category: "MediaOptimizer")
        return data
    }

    /// Optimizes an image from file URL
    /// - Parameter url: File URL to image
    /// - Returns: OptimizedMedia
    /// - Throws: MediaOptimizationError if loading or optimization fails
    static func optimizeImage(from url: URL) throws -> OptimizedMedia {
        guard let image = UIImage(contentsOfFile: url.path) else {
            throw MediaOptimizationError.invalidImage
        }
        return try optimizeImage(image)
    }

    // MARK: - Image Resizing

    /// Resizes image to fit within maxDimension while preserving aspect ratio
    /// - Parameters:
    ///   - image: Original image
    ///   - maxDimension: Maximum width or height
    /// - Returns: Resized image
    private static func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size

        // Check if resize is needed
        guard size.width > maxDimension || size.height > maxDimension else {
            return image  // Already small enough
        }

        // Calculate new size preserving aspect ratio
        let aspectRatio = size.width / size.height
        let newSize: CGSize

        if size.width > size.height {
            // Landscape or square
            newSize = CGSize(width: maxDimension, height: maxDimension / aspectRatio)
        } else {
            // Portrait
            newSize = CGSize(width: maxDimension * aspectRatio, height: maxDimension)
        }

        // Resize using high-quality rendering
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resizedImage = renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        return resizedImage
    }

    // MARK: - Thumbnail Generation

    /// Generates a thumbnail (200x200 JPEG, ~10KB)
    /// - Parameter image: Source image
    /// - Returns: Thumbnail JPEG data
    /// - Throws: MediaOptimizationError if generation fails
    static func generateThumbnail(from image: UIImage) throws -> Data {
        // Resize to thumbnail size (aspect-fill, center-cropped)
        let thumbnail = image.resized(to: thumbnailSize, contentMode: .scaleAspectFill)

        // Convert to JPEG with lower quality for smaller size
        guard let thumbnailData = thumbnail.jpegData(compressionQuality: thumbnailQuality) else {
            throw MediaOptimizationError.thumbnailGenerationFailed
        }

        Log.debug("Generated thumbnail: \(thumbnailData.count) bytes", category: "MediaOptimizer")

        return thumbnailData
    }

    /// Generates a thumbnail from video first frame
    /// - Parameter url: Video file URL
    /// - Returns: Thumbnail JPEG data
    /// - Throws: MediaOptimizationError if generation fails
    static func generateVideoThumbnail(from url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        let time = CMTime(seconds: 0, preferredTimescale: 60)

        return try await withCheckedThrowingContinuation { continuation in
            imageGenerator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                if error != nil {
                    continuation.resume(throwing: MediaOptimizationError.thumbnailGenerationFailed)
                    return
                }
                guard let cgImage else {
                    continuation.resume(throwing: MediaOptimizationError.thumbnailGenerationFailed)
                    return
                }
                do {
                    let data = try generateThumbnail(from: UIImage(cgImage: cgImage))
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: MediaOptimizationError.thumbnailGenerationFailed)
                }
            }
        }
    }

    // MARK: - Video Optimization (Future)

    /// Optimizes video (placeholder for future implementation)
    /// TODO: Implement video transcoding (H.265, 1080p, 2-4 Mbps)
    static func optimizeVideo(from url: URL) async throws -> OptimizedMedia {
        // For now, just read original file and generate thumbnail
        let videoData = try Data(contentsOf: url)
        let thumbnail = try await generateVideoThumbnail(from: url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.load(.tracks)
        let videoTrack = tracks.first(where: { $0.mediaType == .video })
        let size = try await videoTrack?.load(.naturalSize)

        let metadata = MediaMetadata(
            originalSize: videoData.count,
            optimizedSize: videoData.count,  // Not optimized yet
            width: size.map { Int($0.width) },
            height: size.map { Int($0.height) },
            duration: duration,
            mimeType: "video/mp4"
        )

        return OptimizedMedia(
            data: videoData,
            thumbnail: thumbnail,
            metadata: metadata
        )
    }

    // MARK: - Helper Methods

    /// Calculates compression ratio percentage
    private static func compressionRatio(original: Int, optimized: Int) -> Int {
        guard original > 0 else { return 0 }
        let ratio = Double(original - optimized) / Double(original) * 100
        return Int(ratio)
    }
}

// MARK: - UIImage Extension
extension UIImage {

    /// Resize image to fit within size with content mode
    /// - Parameters:
    ///   - targetSize: Target size
    ///   - contentMode: How to fit (aspectFit or aspectFill)
    /// - Returns: Resized image
    func resized(to targetSize: CGSize, contentMode: UIView.ContentMode = .scaleAspectFit) -> UIImage {
        let size = self.size

        let widthRatio = targetSize.width / size.width
        let heightRatio = targetSize.height / size.height

        var newSize: CGSize
        if contentMode == .scaleAspectFit {
            // Fit inside (letterbox/pillarbox)
            let ratio = min(widthRatio, heightRatio)
            newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        } else {
            // Fill (crop)
            let ratio = max(widthRatio, heightRatio)
            newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        }

        // Render at target size
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { context in
            // Center the image
            let origin = CGPoint(
                x: (targetSize.width - newSize.width) / 2,
                y: (targetSize.height - newSize.height) / 2
            )
            self.draw(in: CGRect(origin: origin, size: newSize))
        }
    }
}
