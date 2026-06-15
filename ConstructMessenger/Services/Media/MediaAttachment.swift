//
//  MediaAttachment.swift
//  Construct Messenger
//
//  An outgoing media item the user is about to send. Carries the ORIGINAL source
//  bytes + MIME so the upload pipeline can send them untouched (original quality,
//  Phase 1b) while a display image drives previews and the current compressed path.
//
//  Replaces the bare `[PlatformImage]` the composer used to hand to the send flow —
//  that discarded the original bytes at the picker boundary, which is exactly what
//  original-quality sending needs. In Phase 1a this is a behaviour-preserving refactor:
//  `quality` defaults to `.compressed` and the upload path still optimizes the display
//  image. Phase 1b branches on `quality == .original` to upload `originalData` as-is.
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Quality choice for an outgoing media attachment.
enum MediaQuality: Sendable {
    /// Re-encode / optimize before sending (current default behaviour).
    case compressed
    /// Send the source bytes untouched (Phase 1b).
    case original
}

struct MediaAttachment: Identifiable {
    let id = UUID()
    /// Original, unmodified source bytes (photo picker / file / camera encode).
    let originalData: Data
    /// MIME type of `originalData` (e.g. "image/heic", "image/png", "image/jpeg").
    let mimeType: String
    /// Image for previews and the compressed upload path; nil if not image-decodable.
    let displayImage: PlatformImage?
    /// Whether to send compressed (default) or original.
    var quality: MediaQuality

    init(originalData: Data, mimeType: String, displayImage: PlatformImage?, quality: MediaQuality = .compressed) {
        self.originalData = originalData
        self.mimeType = mimeType
        self.displayImage = displayImage
        self.quality = quality
    }

    /// Wrap an in-memory image (camera capture / drag-drop) — there is no source file,
    /// so the "original" is a high-quality JPEG encode of the image.
    init(image: PlatformImage, quality: MediaQuality = .compressed) {
        let data = image.platformJPEGData(quality: 0.95) ?? Data()
        self.init(originalData: data, mimeType: "image/jpeg", displayImage: image, quality: quality)
    }
}
