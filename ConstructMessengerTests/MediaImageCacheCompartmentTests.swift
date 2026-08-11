//
//  MediaImageCacheCompartmentTests.swift
//  ConstructMessengerTests
//
//  The incident (found by reading the media path on 2026-08-11, not from a device log):
//  "save to Photos" and "share" write out whatever `MediaImageCache` holds for the message, and
//  three call sites were putting small images in there.
//
//    · MediaGalleryViewer.loadImage — for our own sends it read ThumbnailStore (320px, 12 KB cap)
//      under a comment that said "full-res stored locally", so saving your own photo wrote a
//      320px JPEG to the photo library.
//    · ReplyPreviewContent — a 120px reply-bar preview (replyThumbnailSize 40 × 3), for messages
//      in either direction. Reply to a photo, then open it: 120px.
//    · MediaMessageView — the transmitted thumbnail painted as a first frame.
//
//  The cache already carried a comment warning about exactly this ("a data-loss bug wearing the
//  costume of a memory fix"). What the comment could not do was stop `store(_:for:at:)` from
//  reading like "cache this" at the call site. Hence three named compartments, and these tests.
//

import XCTest
@testable import Construct_Messenger

#if canImport(UIKit)
import UIKit

final class MediaImageCacheCompartmentTests: XCTestCase {

    private var cache: MediaImageCache!
    private let messageId = "d6f36cd7-de0d-420e-b59d-c42637e59089"

    override func setUp() {
        super.setUp()
        cache = MediaImageCache()
    }

    /// `scale = 1` on purpose. The renderer defaults to the screen's scale, which on a 3× device
    /// makes a 1440pt square cost 4320×4320×4 = 74 MB — over the cache's 48 MB limit, so NSCache
    /// drops it on insert and every assertion reads nil for the wrong reason. Real photos arrive
    /// through `UIImage(data:)` at scale 1, which is what `decodedBytes` is sized against.
    private func image(side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
    }

    // MARK: - What save-to-Photos may never see

    /// The reply-preview bug: a 120px preview must not become the thing the user saves.
    func testAPosterNeverBecomesTheSavedImage() {
        cache.storePoster(image(side: 120), for: messageId)
        XCTAssertNil(cache.original(for: messageId),
                     "save/share read `original` — a reply-bar preview must not answer that")
    }

    /// The gallery bug: the 320px stored thumbnail painted as a first frame is a poster, and the
    /// same rule applies to it.
    func testAThumbnailFirstPaintNeverBecomesTheSavedImage() {
        cache.storePoster(image(side: 320), for: messageId, at: 2)
        XCTAssertNil(cache.original(for: messageId, at: 2))
    }

    /// The bubble's ~1024px decode is a display copy. It was already separated; this pins it, since
    /// merging the compartments is the obvious "simplification" someone will reach for.
    func testADisplayCopyNeverBecomesTheSavedImage() {
        cache.storeDisplay(image(side: 1024), for: messageId)
        XCTAssertNil(cache.original(for: messageId))
    }

    // MARK: - What must still work

    func testTheOriginalIsWhatComesBack() throws {
        cache.storeOriginal(image(side: 1440), for: messageId)
        let saved = try XCTUnwrap(cache.original(for: messageId))
        XCTAssertEqual(saved.size.width, 1440)
    }

    /// Writing a poster must not evict or replace an original already held for that key — the two
    /// arrive in either order (a bubble may download before or after a reply preview is built).
    func testAPosterDoesNotDisplaceAnOriginalUnderTheSameKey() throws {
        cache.storeOriginal(image(side: 1440), for: messageId)
        cache.storePoster(image(side: 120), for: messageId)
        let saved = try XCTUnwrap(cache.original(for: messageId))
        XCTAssertEqual(saved.size.width, 1440, "the poster overwrote the original")
    }

    // MARK: - Painting

    /// Drawing wants the best available and does not care which compartment it came from.
    func testPaintablePrefersDisplayThenOriginalThenPoster() throws {
        cache.storePoster(image(side: 120), for: messageId)
        XCTAssertEqual(try XCTUnwrap(cache.paintable(for: messageId)).size.width, 120)

        cache.storeOriginal(image(side: 1440), for: messageId)
        XCTAssertEqual(try XCTUnwrap(cache.paintable(for: messageId)).size.width, 1440)

        cache.storeDisplay(image(side: 1024), for: messageId)
        XCTAssertEqual(try XCTUnwrap(cache.paintable(for: messageId)).size.width, 1024,
                       "a bubble should draw the copy sized for it, not decode 1440px again")
    }

    // MARK: - "something to show" is not "done loading"

    /// The trap introduced when the stored thumbnail started being painted for received media too:
    /// the bubble's loader returns early once it has an image, so if a poster counted as loaded, a
    /// download that failed would leave that photo at 320px forever — no error, no retry, and a
    /// tile that looks fine. `resolvedCopy` is the question a loader may act on; `paintable` is not.
    func testAPosterIsPaintableButIsNotAResolvedCopy() {
        cache.storePoster(image(side: 320), for: messageId)
        XCTAssertNotNil(cache.paintable(for: messageId), "there is something to draw")
        XCTAssertNil(cache.resolvedCopy(for: messageId), "but nothing that ends the load")
    }

    func testADisplayCopyOrAnOriginalCountsAsResolved() {
        cache.storeDisplay(image(side: 1024), for: messageId)
        XCTAssertNotNil(cache.resolvedCopy(for: messageId))

        let other = "8b23f2f6-69c4-4300-b382-f610ecfa8bbd"
        cache.storeOriginal(image(side: 1440), for: other)
        XCTAssertNotNil(cache.resolvedCopy(for: other))
    }

    func testCompartmentsAreKeyedByIndex() {
        cache.storeOriginal(image(side: 800), for: messageId, at: 1)
        XCTAssertNil(cache.original(for: messageId, at: 0))
        XCTAssertNotNil(cache.original(for: messageId, at: 1))
    }
}
#endif
