//
//  InlinePreviewPolicyTests.swift
//  ConstructMessengerTests
//
//  Device, 2026-08-11 17:04 — a single photo, with the 12 KB thumbnail cap already in force:
//
//      Local media JSON 396B for 1 item(s)
//      plaintext=3800ch → c0 … c1 … c2 … plaintext=1217ch → c3
//
//  396 bytes of descriptor and four wire messages, four ratchet advances and four RPCs to carry
//  the thumbnail. Prefetch-on-arrival and durable storage landed the same day, which left the
//  thumbnail with one job — the first second — and BlurHash does that inside the descriptor.
//

import XCTest
@testable import Construct_Messenger

final class InlinePreviewPolicyTests: XCTestCase {

    // MARK: - Photos

    /// The saving: one wire message instead of four.
    func testAPhotoWithABlurhashSendsNoThumbnail() {
        XCTAssertFalse(InlinePreviewPolicy.shouldSendThumbnail(isVideo: false, hasBlurhash: true))
    }

    /// `BlurHash.encode` returns an optional and `uploadOriginalImage` derives it from
    /// `displayImage`, which can fail to build. Dropping the thumbnail unconditionally would send
    /// a photo with no preview of any kind and leave the bubble blank until the download finished.
    func testAPhotoWithoutABlurhashKeepsItsThumbnail() {
        XCTAssertTrue(InlinePreviewPolicy.shouldSendThumbnail(isVideo: false, hasBlurhash: false))
    }

    // MARK: - Video

    /// A poster is the only frame that exists before the whole clip is downloaded — and a clip is
    /// exactly what auto-download holds back on, so dropping it would leave video as a smear until
    /// the user spends tens of megabytes.
    func testVideoAlwaysSendsItsPoster() {
        XCTAssertTrue(InlinePreviewPolicy.shouldSendThumbnail(isVideo: true, hasBlurhash: true))
        XCTAssertTrue(InlinePreviewPolicy.shouldSendThumbnail(isVideo: true, hasBlurhash: false))
    }

    // MARK: - Deciding what is a video

    /// This has to agree with `protoMediaType(for:)`, which is a separate spelling of the same
    /// question inside MediaWireCodec. If they drift, a video starts being classified one way for
    /// the wire type and another way for its poster.
    func testVideoDetectionMatchesTheWireTypeSpelling() {
        XCTAssertTrue(InlinePreviewPolicy.isVideo(mimeType: "video/mp4"))
        XCTAssertTrue(InlinePreviewPolicy.isVideo(mimeType: "VIDEO/QUICKTIME"))
        XCTAssertFalse(InlinePreviewPolicy.isVideo(mimeType: "image/heic"))
        XCTAssertFalse(InlinePreviewPolicy.isVideo(mimeType: "image/jpeg"))
        XCTAssertFalse(InlinePreviewPolicy.isVideo(mimeType: "application/pdf"))
    }

    /// An animated GIF is `image/gif` and travels as `.animated`, not `.video`. It follows the
    /// photo rule — stated because "animated" reads like video and the two are decided separately.
    func testAnAnimatedGifFollowsThePhotoRule() {
        XCTAssertFalse(InlinePreviewPolicy.isVideo(mimeType: "image/gif"))
        XCTAssertFalse(InlinePreviewPolicy.shouldSendThumbnail(isVideo: false, hasBlurhash: true))
    }
}
