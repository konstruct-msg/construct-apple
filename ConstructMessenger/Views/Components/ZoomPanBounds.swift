//
//  ZoomPanBounds.swift
//  Construct Messenger
//
//  How far a zoomed image may be panned: no further than its own edge. Shared by the gallery
//  (`MediaGalleryPage`) and the single-image viewer (`FullScreenImageView`), which until
//  2026-10-24 added the drag to the offset with no limit — a zoomed photo could be pushed off
//  the screen and stayed there.
//

import CoreGraphics

enum ZoomPanBounds {
    /// How much of a drag past the edge the image still follows (UIScrollView's constant).
    static let rubberBandFactor: CGFloat = 0.55

    /// The size `.scaledToFit()` gives an image of `imageSize` inside `container`.
    static func fittedSize(of imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return container }
        let ratio = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }

    /// The largest offset on each axis at `scale`: half of what overhangs the container, and
    /// zero on an axis where the zoomed image is still narrower than the container — it stays
    /// centred there, as in Photos.
    static func limit(fitted: CGSize, scale: CGFloat, container: CGSize) -> CGSize {
        CGSize(
            width: max(0, (fitted.width * scale - container.width) / 2),
            height: max(0, (fitted.height * scale - container.height) / 2)
        )
    }

    static func clamped(_ offset: CGSize, limit: CGSize) -> CGSize {
        CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height)
        )
    }

    /// While the finger is down: inside the limit the image follows exactly, past it with
    /// growing resistance, so the edge is felt rather than hit. On release the caller springs
    /// back to `clamped`.
    static func rubberBanded(_ offset: CGSize, limit: CGSize, container: CGSize) -> CGSize {
        CGSize(
            width: band(offset.width, limit: limit.width, dimension: container.width),
            height: band(offset.height, limit: limit.height, dimension: container.height)
        )
    }

    private static func band(_ value: CGFloat, limit: CGFloat, dimension: CGFloat) -> CGFloat {
        let overshoot = abs(value) - limit
        guard overshoot > 0, dimension > 0 else { return value }
        let resisted = (1 - 1 / (overshoot * rubberBandFactor / dimension + 1)) * dimension
        return (limit + resisted) * (value < 0 ? -1 : 1)
    }
}
