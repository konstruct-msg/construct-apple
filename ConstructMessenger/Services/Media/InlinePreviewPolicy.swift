//
//  InlinePreviewPolicy.swift
//  Construct Messenger
//
//  Whether an attachment's preview travels inside the message, or only its BlurHash does.
//
//  A thumbnail is not a file: it goes in the E2EE payload and is chunked with it. Device,
//  2026-08-11 17:04, one photo:
//
//      Local media JSON 396B for 1 item(s)
//      plaintext=3800ch  → c0      payloadBytes = 5100
//      plaintext=3800ch  → c1      payloadBytes = 5100
//      plaintext=3800ch  → c2      payloadBytes = 5100
//      plaintext=1217ch  → c3      payloadBytes = 2550
//
//  The descriptor is 396 bytes. Everything else — four wire messages, four ratchet advances, four
//  RPCs — is the 12 KB thumbnail. That was already the cheap version: before `ThumbnailBudget`
//  capped it, a three-photo album became thirty wire messages and drained the stealth wallet.
//
//  Two changes on 2026-08-11 removed its reason to exist for photos:
//
//    · received media is fetched when the message arrives rather than when the bubble appears
//      (MediaAutoDownloadPolicy), so the full image is usually already there;
//    · it is kept durably rather than in a cache the system may purge (MediaEvictionPolicy).
//
//  What is left for a thumbnail to do is cover the first second, and BlurHash does that for about
//  thirty bytes inside the descriptor that is being sent anyway. So a photo becomes one wire
//  message instead of four.
//

import Foundation

enum InlinePreviewPolicy {

    /// Whether to put the thumbnail bytes on the wire for this item.
    ///
    /// Video keeps it. A poster is the only frame that exists before the whole clip is downloaded,
    /// and a clip is exactly the thing auto-download holds back on — leaving a video as a smear
    /// until the user spends tens of megabytes is a different product, not a saving.
    ///
    /// A photo drops it, but only when a BlurHash is actually present to take its place.
    /// `uploadOriginalImage` derives the BlurHash from `displayImage`, which is optional and can
    /// fail to build; without this condition that path would send a photo with no preview of any
    /// kind, and the bubble would be blank until the download completed. The saving is worth
    /// having, not worth an empty rectangle.
    static func shouldSendThumbnail(isVideo: Bool, hasBlurhash: Bool) -> Bool {
        if isVideo { return true }
        return !hasBlurhash
    }

    /// Mime-type test used at the call site. Kept here so "is this a video" has one spelling —
    /// `protoMediaType(for:)` has its own and they must not drift apart.
    static func isVideo(mimeType: String) -> Bool {
        mimeType.lowercased().hasPrefix("video/")
    }
}
