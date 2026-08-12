//
//  ThumbnailBudget.swift
//  Construct Messenger
//
//  Picking which rendering of a thumbnail to ship, given a hard byte ceiling.
//
//  `MediaOptimizer.generateThumbnail` claimed the ceiling was "a byte count rather than a hope".
//  It was a hope. The budget search it delegates to (`binarySearchQuality`) floors quality at 0.35
//  and returns nil when even that does not fit — and the caller then returned the *q=0.70* data it
//  had rendered first. So the failure path shipped the largest candidate it had produced, not the
//  smallest.
//
//  Device, 2026-08-12 10:53:18, two photos from a 3024×4032 camera roll:
//
//      Thumbnail generated: 31872 bytes
//      Thumbnail generated: 30803 bytes
//
//  against a stated 12 KB cap. Photos no longer put their thumbnail on the wire
//  (InlinePreviewPolicy), so that number was only costing local disk — but two paths still send
//  one, and both were sized by this: a video poster, always, and a photo whose BlurHash failed to
//  build. At 31 KB a video poster is eight wire messages and eight ratchet advances.
//
//  Quality alone cannot bound a detailed image. The full-size path already knew that and solved it
//  with resolution tiers (`progressiveCompress`); the thumbnail path had the search but not the
//  ladder.
//

import CoreGraphics

enum ThumbnailBudget {

    /// Hard ceiling on an inline preview, because a thumbnail is not a file — it travels inside
    /// the E2EE message and is chunked with it.
    ///
    /// Build 593, a three-photo album: thumbnails of 32286 + 44866 + 34195 bytes went into one
    /// message, which became **30 wire messages** (`9dc663cb…` plus `-c1` … `-c29`). Every chunk
    /// is separately sealed and separately redeemable, so the album spent thirty stealth tokens
    /// and hit the issuance ceiling on its own:
    ///
    ///     BlindToken: replenishment failed [rate limited (20/hr)]
    ///       — resourceExhausted: "token issuance rate limit exceeded (30/hr, new-account tier)"
    ///
    /// after which the wallet fell to 6 and every later send ran on the remainder. The token
    /// economics are a separate problem (one token per chunk is wrong), but the payload is the
    /// input that made it bite, and 40 KB of preview for a photo the recipient downloads anyway
    /// is indefensible on its own.
    static let maxBytes = 12 * 1024

    /// Longest-side pixel sizes to try, largest first. Below 128 a preview stops being a preview;
    /// if even that overflows the budget the smallest rendering is shipped anyway, because
    /// something recognisable beats a correct-sized nothing.
    static let dimensionLadder: [CGFloat] = [320, 240, 180, 128]

    /// Which candidate to ship, given renderings produced in ladder order (largest first).
    ///
    /// Returns the index into `candidates`, or nil when there are none.
    ///
    /// Two rules, and the second is the bug this replaces:
    ///   · the first candidate that fits — largest dimension within budget;
    ///   · otherwise the smallest one produced. Never the first, which is what the old code did
    ///     by falling through to the rendering it happened to make before searching.
    static func choose(candidates: [(dimension: CGFloat, bytes: Int)], budget: Int = maxBytes) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if let fitting = candidates.firstIndex(where: { $0.bytes <= budget }) {
            return fitting
        }
        return candidates.indices.min { candidates[$0].bytes < candidates[$1].bytes }
    }
}
