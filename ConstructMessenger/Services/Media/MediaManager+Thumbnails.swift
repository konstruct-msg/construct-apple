//
//  MediaManager+Thumbnails.swift
//  Construct Messenger
//
//  MediaManager: thumbnail generation and storage. Split out of MediaManager.swift.
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
import CoreGraphics
#endif
import CryptoKit
import UniformTypeIdentifiers
import AVFoundation
import GRPCCore

extension MediaManager {
    // MARK: - Thumbnail Operations
    
    /// Generate thumbnail from UIImage
    /// - Parameters:
    ///   - image: Source image
    ///   - maxSize: Maximum dimension (width or height)
    /// - Returns: Thumbnail image data (JPEG)
    /// - Parameter maxSize: **ignored.** `MediaOptimizer` owns the thumbnail dimension and byte
    ///   budget; this parameter has never been forwarded. It stayed in the signature for the
    ///   existing callers, but the log used to print it — claiming "maxSize: 250.0" while the
    ///   optimizer rendered 400px — so it is no longer reported as if it applied.
    func generateThumbnail(from image: PlatformImage, maxSize: CGFloat = 250) -> Data? {
        Log.debug("Generating thumbnail", category: "MediaManager")
        
        do {
            let optimized = try MediaOptimizer.generateThumbnail(from: image)
            Log.debug("Thumbnail generated: \(optimized.count) bytes", category: "MediaManager")
            return optimized
        } catch {
            Log.error("Failed to generate thumbnail: \(error)", category: "MediaManager")
            return nil
        }
    }
    
    /// Generate thumbnail from Data
    /// - Parameters:
    ///   - data: Image data
    ///   - maxSize: Maximum dimension (width or height)
    /// - Returns: Thumbnail image data (JPEG)
    func generateThumbnail(from data: Data, maxSize: CGFloat = 250) -> Data? {
        guard let image = PlatformImage(data: data) else {
            Log.error("Failed to create PlatformImage from data", category: "MediaManager")
            return nil
        }
        
        return generateThumbnail(from: image, maxSize: maxSize)
    }
    
    /// Generate thumbnail with custom UIImage renderer (for MessageBubble compatibility)
    /// - Parameters:
    ///   - image: Source image
    ///   - maxSize: Maximum dimension
    /// - Returns: Thumbnail UIImage
    func generateThumbnailImage(from image: PlatformImage, maxSize: CGFloat) -> PlatformImage {
        let size = image.size
        let scale = size.width > size.height ? maxSize / size.width : maxSize / size.height
        let thumbnailSize = CGSize(width: size.width * scale, height: size.height * scale)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
        }
        #else
        // macOS: use explicit bitmap rep to avoid HDR gain map / CGBitmap delegate warnings on certain images
        let dest = NSImage(size: thumbnailSize)
        if let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(thumbnailSize.width),
            pixelsHigh: Int(thumbnailSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) {
            bitmap.size = thumbnailSize
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = ctx
                // Draw source without forcing HDR headroom mismatch
                image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                           from: NSRect(origin: .zero, size: size),
                           operation: .copy, fraction: 1.0)
            }
            NSGraphicsContext.restoreGraphicsState()
            dest.addRepresentation(bitmap)
        } else {
            dest.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: thumbnailSize),
                       from: NSRect(origin: .zero, size: size),
                       operation: .copy, fraction: 1.0)
            dest.unlockFocus()
        }
        return dest
        #endif
    }
    
    // MARK: - Thumbnail Storage

    /// These used to live in UserDefaults — the header here said "temporary solution" and it was
    /// still true four months later, at 37 MB across 994 keys and nine times the CFPreferences
    /// limit. `ThumbnailStore` holds the reasoning; these three stay as the call-site API because
    /// twelve views and two services already speak it.

    func storeThumbnail(_ thumbnailData: Data, for messageId: String, at index: Int = 0) {
        ThumbnailStore.shared.store(thumbnailData, for: messageId, at: index)
        Log.debug("Stored thumbnail[\(index)] for message: \(messageId)", category: "MediaManager")
    }

    func retrieveThumbnail(for messageId: String, at index: Int = 0) -> Data? {
        ThumbnailStore.shared.load(for: messageId, at: index)
    }

    func retrieveThumbnail(for messageId: String) -> Data? {
        retrieveThumbnail(for: messageId, at: 0)
    }

    func removeThumbnail(for messageId: String) {
        ThumbnailStore.shared.remove(for: messageId)
    }
}
