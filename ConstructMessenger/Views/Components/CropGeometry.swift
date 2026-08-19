//
//  CropGeometry.swift
//  Construct Messenger
//
//  The arithmetic behind the crop editor, kept away from the gestures that drive it.
//

import CoreGraphics
import Foundation

// MARK: - Aspect

/// The shape of the crop window.
///
/// `free` follows the image, so opening the editor and pressing Done returns the picture
/// unchanged — the editor must never be a lossy no-op.
enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free
    case square
    case fourThree
    case sixteenNine

    var id: String { rawValue }

    /// Width ÷ height, or nil when the window follows the image.
    var ratio: CGFloat? {
        switch self {
        case .free:        return nil
        case .square:      return 1
        case .fourThree:   return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        }
    }

    /// Shown on the segment. Not localized on purpose: these are notation, not words, and
    /// they read the same in every locale we ship.
    var label: String {
        switch self {
        case .free:        return "FREE"
        case .square:      return "1:1"
        case .fourThree:   return "4:3"
        case .sixteenNine: return "16:9"
        }
    }
}

// MARK: - Orientation

/// Quarter turns and a mirror, accumulated before any pixels move.
///
/// Rotating the bitmap on every tap would resample the image four times for a full turn.
/// This carries the intent instead, and the pixels are touched once, on confirm.
struct CropOrientation: Equatable, Sendable {
    /// Clockwise quarter turns, always normalised to 0…3.
    private(set) var quarterTurns: Int = 0
    private(set) var mirrored: Bool = false

    static let identity = CropOrientation()

    var isIdentity: Bool { quarterTurns == 0 && !mirrored }

    mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
    }

    mutating func mirror() {
        mirrored.toggle()
    }

    /// Whether the visible width and height are swapped relative to the source.
    var swapsAxes: Bool { quarterTurns % 2 == 1 }

    /// Source size as it appears after the turns.
    func apply(to size: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }
}

// MARK: - Geometry

enum CropGeometry {

    /// The crop window inside `container`, as large as the aspect allows.
    ///
    /// For `free` the window takes the image's own aspect, so the default crop is the whole
    /// picture. For a fixed aspect the window is the largest rectangle of that shape that
    /// fits — letterboxed on whichever axis runs out first.
    static func cropWindow(container: CGSize, aspect: CropAspect, imageAspect: CGFloat) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        let target = aspect.ratio ?? max(imageAspect, 0.0001)
        let containerAspect = container.width / container.height
        return target > containerAspect
            ? CGSize(width: container.width, height: container.width / target)
            : CGSize(width: container.height * target, height: container.height)
    }

    /// Scale at which the image just covers the window — the floor for pinch.
    ///
    /// Below it the window would show empty space, and a crop containing nothing is not a
    /// picture the sender chose.
    static func minimumScale(displayedImageSize: CGSize, window: CGSize) -> CGFloat {
        guard displayedImageSize.width > 0, displayedImageSize.height > 0 else { return 1 }
        return max(window.width / displayedImageSize.width,
                   window.height / displayedImageSize.height)
    }

    /// How far the image may be dragged before an edge would enter the window.
    static func offsetLimit(displayedImageSize: CGSize, scale: CGFloat, window: CGSize) -> CGSize {
        CGSize(
            width: max(0, (displayedImageSize.width * scale - window.width) / 2),
            height: max(0, (displayedImageSize.height * scale - window.height) / 2)
        )
    }

    static func clampedOffset(_ offset: CGSize, displayedImageSize: CGSize, scale: CGFloat, window: CGSize) -> CGSize {
        let limit = offsetLimit(displayedImageSize: displayedImageSize, scale: scale, window: window)
        return CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height)
        )
    }

    /// The region of the source to keep, in source pixels.
    ///
    /// `displayedImageSize` is the on-screen size at scale 1; `scale` and `offset` are the
    /// gesture state. The result is intersected with the image so a rounding error at the
    /// edge cannot ask for pixels that do not exist — `CGImage.cropping(to:)` returns nil for
    /// an out-of-bounds rect, and the editor would silently hand back the uncropped original.
    static func cropRect(
        imagePixelSize: CGSize,
        displayedImageSize: CGSize,
        scale: CGFloat,
        offset: CGSize,
        window: CGSize
    ) -> CGRect {
        guard displayedImageSize.width > 0, scale > 0 else {
            return CGRect(origin: .zero, size: imagePixelSize)
        }
        let scaled = CGSize(width: displayedImageSize.width * scale,
                            height: displayedImageSize.height * scale)
        let clamped = clampedOffset(offset, displayedImageSize: displayedImageSize, scale: scale, window: window)

        let originX = (scaled.width - window.width) / 2 - clamped.width
        let originY = (scaled.height - window.height) / 2 - clamped.height

        // One factor for both axes: the displayed image keeps the source's aspect, so a
        // separate x and y scale would only differ by rounding and would shear the crop.
        let pixelsPerPoint = imagePixelSize.width / scaled.width

        let rect = CGRect(
            x: originX * pixelsPerPoint,
            y: originY * pixelsPerPoint,
            width: window.width * pixelsPerPoint,
            height: window.height * pixelsPerPoint
        )

        let bounds = CGRect(origin: .zero, size: imagePixelSize)
        let safe = rect.intersection(bounds)
        return safe.isNull || safe.width < 1 || safe.height < 1 ? bounds : safe
    }

    /// Whether the edit changes anything. A crop covering the whole image with no rotation
    /// must not re-encode it: that would cost a JPEG generation for nothing, and on a
    /// transparent PNG it is the difference between a sticker and a black rectangle.
    static func isNoOp(cropRect: CGRect, imagePixelSize: CGSize, orientation: CropOrientation) -> Bool {
        guard orientation.isIdentity else { return false }
        let tolerance: CGFloat = 1
        return abs(cropRect.origin.x) < tolerance
            && abs(cropRect.origin.y) < tolerance
            && abs(cropRect.width - imagePixelSize.width) < tolerance
            && abs(cropRect.height - imagePixelSize.height) < tolerance
    }
}
