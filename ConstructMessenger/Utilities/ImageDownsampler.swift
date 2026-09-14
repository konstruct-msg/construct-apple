//
//  ImageDownsampler.swift
//  Construct Messenger
//
//  Decode an image at the size it will actually be drawn, instead of at the size it was taken.
//
//  Nothing in this app downsampled before 2026-08-10 — every display path went through
//  `UIImage(data:)`, which decodes at full resolution. A photo off the camera is 1440×2048, which
//  is ~600 KB as JPEG and **~11.8 MB decoded**, and it was that 11.8 MB that got held, cached and
//  drawn into a chat bubble roughly 300 pt wide. The device log shows the bill: footprint 127 MB
//  → 447 MB across nine minutes of ordinary chatting, and a main thread busy scaling bitmaps
//  twenty times larger than the destination.
//
//  `CGImageSourceCreateThumbnailAtIndex` never materialises the full bitmap — the decode happens
//  straight to the target size, so the peak allocation is the small image, not the large one.
//  That is the whole point, and it is why this cannot be replaced by `UIImage(data:)` followed by
//  a resize.
//

import Foundation
import CoreGraphics
import ImageIO

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum ImageDownsampler {

    /// Longest-side pixel budget for an image drawn in a chat bubble.
    ///
    /// A bubble is at most ~300 pt wide; at 3× that is 900 px, and the gallery — which does want
    /// full resolution — does not read this cache. Rounded up to 1024 so a landscape photo still
    /// has pixels to spare when the bubble is on an iPad.
    static let bubbleMaxPixelSize = 1024

    /// The pixel budget for a target drawn at `points`, given a screen `scale`.
    ///
    /// Pure and separately testable: the arithmetic is the part that silently rots when someone
    /// changes a layout constant, and the failure mode (a blurry photo, or a 12 MB decode that
    /// looks fine) is invisible in review.
    static func pixelBudget(forPoints points: CGFloat, scale: CGFloat, cap: Int = bubbleMaxPixelSize) -> Int {
        guard points > 0, scale > 0 else { return cap }
        return min(cap, Int((points * scale).rounded(.up)))
    }

    /// Decode `data` so its longest side is at most `maxPixelSize` pixels.
    ///
    /// Returns nil only when the data is not a decodable image — a caller that gets nil should
    /// treat it exactly as it treated `PlatformImage(data:)` returning nil.
    ///
    /// **Both platforms.** The decode is CoreGraphics and ImageIO, which are the same on macOS;
    /// only the wrapper type differs, and `PlatformImage` already names it. This was `#if
    /// canImport(UIKit)` until 2026-08-27, which made the whole function absent on macOS and the
    /// unguarded call site in `MediaMessageView` the one thing standing between the desktop target
    /// and a build. Guarding the *call site* instead would have compiled and been worse: macOS
    /// would have fallen back to a full-resolution decode, which is the 11.8 MB this file exists
    /// to avoid, on the platform where a chat window is smaller relative to the photo, not larger.
    static func image(from data: Data, maxPixelSize: Int = bubbleMaxPixelSize) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let options = [
            // `…FromImageAlways`, not `…IfAbsent`: an embedded EXIF thumbnail is typically 160px
            // and would be drawn as a blurry mess. We want a real decode, just a smaller one.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceShouldCacheImmediately: true          // decode now, off the render pass
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            // Not decodable as a thumbnail (some HEIC edge cases). Fall back rather than showing
            // nothing — a large decode is worse than a leak of correctness, not the reverse.
            return PlatformImage(data: data)
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        // NSImage needs the size in points; the CGImage is already at the target pixel size, and
        // passing `.zero` would make it draw at 72 dpi regardless of the screen.
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
