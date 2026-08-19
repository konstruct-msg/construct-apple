//
//  MediaAttachment.swift
//  Construct Messenger
//
//  An outgoing media item the user is about to send. Carries the ORIGINAL source
//  bytes + MIME so the upload pipeline can send them untouched (original quality)
//  while a display image drives previews and the current compressed path.
//
//  Video: `kind == .video` carries a `videoURL` (local temp copy of the picked movie)
//  plus a poster frame + duration; the upload path transcodes to `videoQuality` before
//  encrypting. Images keep the binary `quality` (compressed / original) switch.
//

import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Quality choice for an outgoing image attachment.
enum MediaQuality: Sendable {
    /// Re-encode / optimize before sending (current default behaviour).
    case compressed
    /// Send the source bytes untouched.
    case original
}

/// Video send quality. Maps to an `AVAssetExportSession` preset; `.original` is passthrough.
enum VideoQuality: String, Sendable, CaseIterable {
    case p720
    case p1080
    case original

    var exportPreset: String {
        switch self {
        case .p720:     return AVAssetExportPreset1280x720
        case .p1080:    return AVAssetExportPreset1920x1080
        case .original: return AVAssetExportPresetPassthrough
        }
    }

    /// Short UI label ("720" / "1080" / localized "Original").
    var shortLabel: String {
        switch self {
        case .p720:     return "720"
        case .p1080:    return "1080"
        case .original: return NSLocalizedString("quality_original", comment: "Original media quality")
        }
    }
}

enum MediaKind: Sendable {
    case image
    case video
}

// @unchecked Sendable: the only non-Sendable field is the immutable display image
// (UIImage/NSImage are safe to read across threads); all other fields are value types.
// Lets attachments be captured by concurrent upload tasks.
struct MediaAttachment: Identifiable, @unchecked Sendable {
    let id = UUID()
    /// Whether this attachment is a still image or a video.
    let kind: MediaKind
    /// Original, unmodified source bytes (photo picker / file / camera encode). Empty for video.
    let originalData: Data
    /// MIME type of the source (e.g. "image/heic", "image/jpeg", "video/mp4").
    let mimeType: String
    /// Image, or the video poster frame — drives previews and the bubble thumbnail.
    let displayImage: PlatformImage?
    /// Whether to send the image compressed (default) or original. Ignored for video.
    var quality: MediaQuality
    /// Video send quality. Ignored for images.
    var videoQuality: VideoQuality
    /// Local temp file for the picked video (nil for images).
    let videoURL: URL?
    /// Video duration in seconds (nil for images).
    let duration: TimeInterval?

    // MARK: - Image initializers

    init(originalData: Data, mimeType: String, displayImage: PlatformImage?, quality: MediaQuality = .compressed) {
        self.kind = .image
        self.originalData = originalData
        self.mimeType = mimeType
        self.displayImage = displayImage
        self.quality = quality
        self.videoQuality = .p1080
        self.videoURL = nil
        self.duration = nil
    }

    /// Wrap an in-memory image (camera capture, drag-drop, or the crop editor's output) —
    /// there is no source file, so the "original" is an encode of the image itself.
    ///
    /// PNG when the image uses transparency, JPEG otherwise. JPEG has no alpha channel, so
    /// encoding a sticker here would flatten it to black before it ever reached the send
    /// path — the same defect fixed there on 2026-08-19, re-entered one boundary earlier.
    /// Camera frames and photos are opaque and still take the small lossy encode.
    init(image: PlatformImage, quality: MediaQuality = .compressed) {
        #if canImport(UIKit)
        if MediaOptimizer.usesAlpha(image), let png = image.pngData() {
            self.init(originalData: png, mimeType: "image/png", displayImage: image, quality: quality)
            return
        }
        #endif
        let data = image.platformJPEGData(quality: 0.95) ?? Data()
        self.init(originalData: data, mimeType: "image/jpeg", displayImage: image, quality: quality)
    }

    // MARK: - Video initializer

    init(
        videoURL: URL,
        poster: PlatformImage?,
        duration: TimeInterval?,
        mimeType: String = "video/mp4",
        videoQuality: VideoQuality = .p1080
    ) {
        self.kind = .video
        self.originalData = Data()
        self.mimeType = mimeType
        self.displayImage = poster
        self.quality = .compressed
        self.videoQuality = videoQuality
        self.videoURL = videoURL
        self.duration = duration
    }
}
