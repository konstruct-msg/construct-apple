//
//  MediaManager+Upload.swift
//  Construct Messenger
//
//  MediaManager: image, video, file, audio and avatar uploads with retry. Split out of MediaManager.swift.
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
    // MARK: - Upload Operations
    
    /// Upload image for chat message
    /// - Parameters:
    ///   - image: UIImage to upload
    ///   - recipientId: User ID to encrypt media key for
    /// - Returns: Media metadata for message content
    func uploadImage(
        _ attachment: MediaAttachment,
        for recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaMessageData {
        // Original-quality: upload the source bytes untouched (preserve HEIC/PNG + mime).
        if attachment.quality == .original {
            return try await uploadOriginalImage(attachment, for: recipientId, onProgress: onProgress)
        }

        Log.info("Uploading image for recipient: \(recipientId) (compressed)", category: "MediaManager")
        guard let image = attachment.displayImage ?? PlatformImage(data: attachment.originalData) else {
            throw MediaOptimizationError.conversionFailed
        }
        let optimized = try MediaOptimizer.optimizeImage(image)

        // Upload with 1 automatic retry on stream failure
        let uploadResult = try await Self.uploadWithRetry(data: optimized.data, mimeType: optimized.metadata.mimeType, reuse: .forSend(to: recipientId, forwarded: attachment.isForwarded), onProgress: onProgress)
        Log.info("Image uploaded: \(uploadResult.mediaId)", category: "MediaManager")

        let width = optimized.metadata.width
        let height = optimized.metadata.height
        let blurhash = BlurHash.encode(image)

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: uploadResult.mimeType,
            size: uploadResult.encryptedSize,
            width: width,
            height: height,
            duration: nil,
            thumbnail: optimized.thumbnail,
            hash: uploadResult.hash,
            filename: nil,
            blurhash: blurhash
        )
    }

    /// Upload the original picture (no JPEG re-encode), preserving the real mime
    /// (HEIC/PNG/JPEG) — without its metadata: the library's file carries GPS, capture time and
    /// camera, and went out with them until 2026-09-30 (`ImageMetadataStripper`). A small JPEG
    /// thumbnail + pixel dimensions are still derived from the display image so bubbles render
    /// before the full download.
    private func uploadOriginalImage(
        _ attachment: MediaAttachment,
        for recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaMessageData {
        guard let data = ImageMetadataStripper.strip(attachment.originalData) else {
            throw MediaOptimizationError.conversionFailed
        }
        Log.info("Uploading ORIGINAL image for recipient: \(recipientId) (mime=\(attachment.mimeType), \(data.count) bytes)", category: "MediaManager")
        guard Int64(data.count) <= MessageSizeLimits.maxUploadBytes else {
            throw MediaUploadError.fileTooLarge(data.count, Int(MessageSizeLimits.maxUploadBytes))
        }
        let uploadResult = try await Self.uploadWithRetry(data: data, mimeType: attachment.mimeType, reuse: .forSend(to: recipientId, forwarded: attachment.isForwarded), onProgress: onProgress)
        Log.info("Original image uploaded: \(uploadResult.mediaId)", category: "MediaManager")

        // Wire budget: this thumbnail's only consumer is `MediaWireCodec.albumContent`. The local
        // placeholder copy is generated separately in MediaUploadManager at the disk budget.
        let thumbnail = attachment.displayImage.flatMap {
            try? MediaOptimizer.generateThumbnail(from: $0, budget: ThumbnailBudget.wireMaxBytes)
        }
        let (width, height) = Self.pixelDimensions(of: attachment.displayImage)
        let blurhash = attachment.displayImage.flatMap { BlurHash.encode($0) }

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: attachment.mimeType,
            size: uploadResult.encryptedSize,
            width: width,
            height: height,
            duration: nil,
            thumbnail: thumbnail,
            hash: uploadResult.hash,
            filename: nil,
            blurhash: blurhash
        )
    }

    // MARK: - Video upload

    /// Transcode a picked video to the requested quality, then encrypt + upload it.
    /// Progress: transcode maps to 0…0.5, upload to 0.5…1.0, so the sender sees a moving
    /// bar through the (otherwise silent) compression phase — the long part for big clips.
    func uploadVideo(
        _ attachment: MediaAttachment,
        for recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaMessageData {
        guard let sourceURL = attachment.videoURL else {
            throw MediaUploadError.uploadFailed("Video attachment missing source URL")
        }
        Log.info("Uploading video for \(recipientId) (quality=\(attachment.videoQuality.rawValue))", category: "MediaManager")

        let asset = AVURLAsset(url: sourceURL)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")

        let transcodedURL = try await Self.transcodeVideo(
            asset: asset,
            to: outputURL,
            render: attachment.presentation == .videoNote ? Self.videoNoteRender : attachment.videoQuality.render,
            timeRange: attachment.timeRange,
            onProgress: onProgress.map { cb in { @Sendable v in cb(v * 0.5) } }
        )
        defer {
            try? FileManager.default.removeItem(at: transcodedURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let videoData = try Data(contentsOf: transcodedURL)
        guard Int64(videoData.count) <= MessageSizeLimits.maxUploadBytes else {
            throw MediaUploadError.fileTooLarge(videoData.count, Int(MessageSizeLimits.maxUploadBytes))
        }

        let uploadResult = try await Self.uploadWithRetry(
            data: videoData,
            mimeType: "video/mp4",
            reuse: .forSend(to: recipientId, forwarded: attachment.isForwarded),
            onProgress: onProgress.map { cb in { @Sendable v in cb(0.5 + v * 0.5) } }
        )
        Log.info("Video uploaded: \(uploadResult.mediaId) (\(videoData.count) bytes)", category: "MediaManager")

        let (width, height) = await Self.videoDisplayDimensions(AVURLAsset(url: transcodedURL))
        let loadedDuration = (try? await asset.load(.duration))?.seconds
        let duration = attachment.duration ?? loadedDuration
        // A video poster always goes on the wire — the recipient cannot prefetch a whole video on
        // arrival — so it is sized to fit one chunk rather than to look best on disk.
        let thumbnail = attachment.displayImage.flatMap {
            try? MediaOptimizer.generateThumbnail(from: $0, budget: ThumbnailBudget.wireMaxBytes)
        }
        let blurhash = attachment.displayImage.flatMap { BlurHash.encode($0) }

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: "video/mp4",
            size: uploadResult.encryptedSize,
            width: width,
            height: height,
            duration: duration,
            thumbnail: thumbnail,
            hash: uploadResult.hash,
            filename: nil,
            blurhash: blurhash,
            presentation: attachment.presentation
        )
    }

    /// Export `asset` to `outputURL` at the given quality. `.original` uses passthrough
    /// (container remux only). Reports export progress via `onProgress` (0…1).
    ///
    /// `.p720` / `.p1080` are HEVC — about half the bytes of H.264 at the same quality, and a
    /// hardware encoder on every supported iPhone — scaled to fit the quality's box, in SDR and at
    /// no more than 30 frames a second (`sdrVideoComposition`). H.264 at the same size only when
    /// the HEVC preset refuses the source. Until 2026-10-04 both qualities were H.264 presets.
    static func transcodeVideo(
        asset: AVURLAsset,
        to outputURL: URL,
        quality: VideoQuality,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try await transcodeVideo(asset: asset, to: outputURL, render: quality.render, onProgress: onProgress)
    }

    /// A video note: the centre 3:4 of the frame — what the viewfinder showed — at 720×960.
    static let videoNoteRender = VideoRender(
        bounds: (960, 720), cropAspect: 3.0 / 4.0, h264Preset: AVAssetExportPreset1280x720
    )

    /// `render` nil is passthrough; `timeRange` nil sends the whole asset.
    nonisolated static func transcodeVideo(
        asset: AVAsset,
        to outputURL: URL,
        render: VideoRender?,
        timeRange: CMTimeRange? = nil,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)

        // The picture and nothing about where or when it was shot. Exported directly, the session
        // copies the source's metadata — a camera's location and capture date went out with every
        // video until 2026-09-30, at every quality — and neither `metadata = []` (read as "unset")
        // nor `.forSharing()` (keeps the date) stops it. A composition of the source's tracks has
        // no metadata to copy; the orientation is the track's transform and is carried over.
        let source = try await metadataFreeComposition(of: asset, range: timeRange)

        let export: AVAssetExportSession
        if let render {
            var chosen: AVAssetExportSession?
            for preset in [AVAssetExportPresetHEVC1920x1080, render.h264Preset]
            where await AVAssetExportSession.compatibility(ofExportPreset: preset, with: source, outputFileType: .mp4) {
                chosen = AVAssetExportSession(asset: source, presetName: preset)
                if chosen != nil { break }
            }
            guard let chosen else {
                throw MediaUploadError.uploadFailed("Cannot create video export session")
            }
            chosen.videoComposition = try await sdrVideoComposition(for: source, render: render)
            export = chosen
        } else {
            guard let passthrough = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough) else {
                throw MediaUploadError.uploadFailed("Cannot create video export session")
            }
            export = passthrough
        }

        // `states(updateInterval:)` is the API for observing an export while `export(to:)` runs;
        // this task only reads progress from it and is cancelled when the export returns.
        nonisolated(unsafe) let progressSource = export
        let progressTask: Task<Void, Never>? = onProgress.map { cb in
            Task {
                for await state in progressSource.states(updateInterval: 0.3) {
                    if case .exporting(let progress) = state {
                        cb(progress.fractionCompleted)
                    }
                }
            }
        }
        defer { progressTask?.cancel() }

        try await export.export(to: outputURL, as: .mp4)
        onProgress?(1.0)
        return outputURL
    }

    /// Most frames a second a compressed video keeps. A phone's 60 — or a slow-motion clip's 240 —
    /// is mostly bytes nobody sees in a chat.
    nonisolated static let maxSentFrameRate: Float = 30

    /// How the picture is rendered for `.p720` / `.p1080` and video notes: upright, centre-cropped
    /// to `render.cropAspect` if it names one, scaled to fit `render.bounds` (never up), in Rec. 709
    /// SDR, at most `maxSentFrameRate`. The rotation is applied to the pixels, so
    /// the exported track's transform is identity.
    ///
    /// SDR because an iPhone films HDR (HLG / Dolby Vision) by default: it costs bits, and on a
    /// screen or a player that does not tone-map it the picture comes out washed out or blown out.
    /// The H.264 presets always converted; the HEVC ones keep HDR unless the composition says not to.
    /// Nil for a source with no video track — the preset then exports the audio as it would.
    private nonisolated static func sdrVideoComposition(
        for source: AVComposition,
        render: VideoRender
    ) async throws -> AVVideoComposition? {
        let bounds = render.bounds
        guard let track = try await source.loadTracks(withMediaType: .video).first else { return nil }
        let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        // Where the transform puts the picture. A camera's transform carries the translation
        // that brings it back to the origin; one that does not would render off the canvas.
        let placed = CGRect(origin: .zero, size: natural).applying(transform)
        guard placed.width > 0, placed.height > 0 else { return nil }

        // The centre of the upright picture at `cropAspect`, or all of it.
        var width = placed.width, height = placed.height
        if let aspect = render.cropAspect {
            if width / height > aspect { width = height * aspect } else { height = width / aspect }
        }
        let cropX = (placed.width - width) / 2, cropY = (placed.height - height) / 2

        let scale = min(1, bounds.long / max(width, height), bounds.short / min(width, height))
        // Encoders want even dimensions; rounding down keeps the picture inside the box.
        let even = { (v: CGFloat) in max(2, (v * scale / 2).rounded(.down) * 2) }

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: even(width), height: even(height))
        let rate = fps > 0 ? min(fps, maxSentFrameRate) : maxSentFrameRate
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // Turn the picture upright, move the kept part to the origin, then shrink it there.
        let upright = transform
            .concatenating(CGAffineTransform(translationX: -placed.minX - cropX, y: -placed.minY - cropY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        layer.setTransform(upright, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await source.load(.duration))
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    /// The video and audio tracks of `asset`, whole, in a composition that carries none of its
    /// metadata. See `transcodeVideo`.
    /// `range` nil is the whole asset; a range keeps that stretch, starting at zero — a trim made
    /// here is exact to the frame, since every export but passthrough re-encodes.
    private nonisolated static func metadataFreeComposition(of asset: AVAsset, range: CMTimeRange? = nil) async throws -> AVComposition {
        let composition = AVMutableComposition()
        let whole = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let range = range.map { $0.intersection(whole) } ?? whole
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let copy = composition.addMutableTrack(
                withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            if track.mediaType == .video {
                copy.preferredTransform = try await track.load(.preferredTransform)
            }
        }
        return composition
    }

    /// Orientation-corrected display dimensions of a video's first video track.
    private static func videoDisplayDimensions(_ asset: AVURLAsset) async -> (Int?, Int?) {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return (nil, nil)
        }
        let applied = size.applying(transform)
        return (Int(abs(applied.width)), Int(abs(applied.height)))
    }

    /// Persist the full plaintext of a just-sent media item under its `mediaId`, into the
    /// same memory + disk cache the download path reads. The sender's bubble/gallery then
    /// resolve full quality via the normal `downloadAndDecryptMedia` cache-first path —
    /// no network, no low-res-thumbnail fallback.
    /// Seed the local caches with something we just uploaded. Called from `uploadWithRetry` for
    /// every path — see the note there.
    func cacheSentMedia(_ plaintext: Data, mediaId: String) {
        saveToDiskcache(plaintext, mediaId: mediaId)
        storeInMemoryCache(plaintext, mediaId: mediaId)
        // The quota used to be enforced only on the download path, so sent media grew the disk
        // cache with nothing bounding it until the user happened to receive something. That was
        // survivable while only images and video came through here; now every upload does.
        evictToQuota()
    }

    /// Pixel dimensions of an image (nil when unavailable).
    private static func pixelDimensions(of image: PlatformImage?) -> (Int?, Int?) {
        guard let image else { return (nil, nil) }
        #if canImport(UIKit)
        return (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
        #else
        return (Int(image.size.width), Int(image.size.height))
        #endif
    }

    /// Uploads data with up to 2 automatic retries on transient gRPC/VEIL stream failures.
    /// Checks MediaSendCache first — identical plaintext within the 30-minute TTL window
    /// skips re-encryption and re-upload entirely.
    static func uploadWithRetry(
        data: Data,
        mimeType: String,
        reuse: MediaUploadReuse,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaServiceClient.UploadedMedia {
        // Cache hit: same plaintext already uploaded recently → reuse mediaId + AES key.
        // Safe: the key is carried inside the DR-encrypted message payload, so each
        // recipient still gets an independent encrypted envelope.
        if let cached = await MediaSendCache.shared.cachedUpload(for: data, reuse: reuse) {
            Log.info("Media send cache hit — reusing \(cached.mediaId)", category: "MediaManager")
            onProgress?(1.0)
            MediaManager.shared.cacheSentMedia(data, mediaId: cached.mediaId)
            return cached
        }

        let result = try await retryingUpload(
            delays: NetworkTiming.Media.retryDelaysNs,
            waitForTunnel: { await VeilTunnelWait.untilRouted() }
        ) {
            try await MediaServiceClient.shared.uploadData(data, mimeType: mimeType, onProgress: onProgress)
        }
        onProgress?(1.0)
        await MediaSendCache.shared.storeUpload(result, for: data, reuse: reuse)
        // Keep the plaintext locally so the SENDER never re-downloads their own upload.
        //
        // This used to be the caller's job, and three of the six upload paths did it while
        // three did not — so playing back your own voice note fetched it from the server,
        // seconds after the microphone produced it. There is nothing to decide here and no
        // reason for a caller to know about it: every successful upload passes through this
        // function, so the cache is seeded here and the per-path calls are gone.
        //
        // `data` is exactly what went to the server on every path (video: the transcoded
        // bytes; file: the possibly-ZLIB-compressed bytes), which is also exactly what
        // `downloadAndDecryptMedia` returns — so a cache hit and a download are the same
        // value, not merely similar ones.
        MediaManager.shared.cacheSentMedia(data, mediaId: result.mediaId)
        return result
    }

    static let maxTunnelWaits = 3

    /// The upload's retry rule, apart from the network. A dropped RPC is tried again after each
    /// delay; VEIL `on` with no tunnel yet waits for the tunnel and does not spend a try — the
    /// upload has not started, so nothing about it failed.
    static func retryingUpload<T>(
        delays: [UInt64],
        waitForTunnel: () async -> Bool,
        _ upload: () async throws -> T
    ) async throws -> T {
        // .cancelled       → in-flight RPC killed when the persistent connection was torn down
        // .unavailable     → server/transport unreachable
        // .deadlineExceeded → upload timed out (large file on slow link)
        // .unknown         → gRPC-swift wraps Swift CancellationError from the transport as .unknown
        //                     when VEIL proxy restarts mid-stream (e.g. foreground wake)
        //                     log: unknown: "The transport threw an unexpected error." (cause: "CancellationError()")
        let retryableCodes: Set<RPCError.Code> = [.cancelled, .unavailable, .deadlineExceeded, .unknown]
        var lastError: Error?
        var attempt = 0
        // A tunnel that comes up and drops again before the upload starts is waited for again,
        // a few times — not without end.
        var tunnelWaits = 0
        while attempt <= delays.count {
            do {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: delays[attempt - 1])
                }
                return try await upload()
            } catch let notUp as VeilTunnelNotUp {
                Log.info("Upload waits for the VEIL tunnel", category: "MediaManager")
                tunnelWaits += 1
                guard tunnelWaits <= maxTunnelWaits, await waitForTunnel() else { throw notUp }
                continue
            } catch let error as GRPCCore.RPCError where retryableCodes.contains(error.code) {
                lastError = error
                Log.info("Upload dropped (code=\(error.code)) — will retry", category: "MediaManager")
            }
            attempt += 1
        }
        throw lastError ?? RPCError(code: .unknown, message: "Upload failed: no error captured")
    }

    /// Downloads encrypted media data with up to 3 automatic retries on transient VEIL/stream failures.
    static func downloadWithRetry(mediaId: String, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        let retryableCodes: Set<RPCError.Code> = [.cancelled, .unavailable, .deadlineExceeded, .unknown]
        // Generous delays: media downloads take 40 s to fail under DPI; VEIL needs ~1–2 s to come up.
        let delays: [UInt64] = [3_000_000_000, 8_000_000_000, 15_000_000_000]

        // Pre-flight: if DPI was confirmed this session and VEIL proxy isn't routing yet,
        // start it and wait before the first download attempt.  Without this, a long-running
        // streaming RPC goes direct and gets silently blocked by the middlebox.
        await ensureVEILForMedia()

        var lastError: Error?
        for (index, delay) in ([0] + delays.map { Optional($0) }).enumerated() {
            do {
                if let ns = delay {
                    try await Task.sleep(nanoseconds: ns)
                }
                return try await MediaServiceClient.shared.downloadEncryptedFile(mediaId: mediaId, onProgress: onProgress)
            } catch let error as GRPCCore.RPCError where retryableCodes.contains(error.code) {
                lastError = error
                Log.info("Download dropped (code=\(error.code)) — will retry", category: "MediaManager")
                // Start VEIL after any transient failure and wait for it to be ready so the
                // next attempt uses the obfs4 tunnel instead of the blocked direct path.
                if error.code == .unavailable || error.code == .deadlineExceeded {
                    await ensureVEILForMedia()
                }
                _ = index  // suppress unused-variable warning
            }
        }
        throw lastError ?? RPCError(code: .unknown, message: "Download failed: no error captured")
    }

    /// No-op: ConnectionLoop manages proxy lifecycle — readiness is guaranteed
    /// when veilProxyPort() is non-nil and GRPCCallExecutor routes through it.
    private static func ensureVEILForMedia() async {}

    /// Upload a file (document, PDF, etc.) for a chat message.
    /// Text-based files are transparently compressed with ZLIB before encryption if beneficial.
    /// - Parameter url: Security-scoped URL of the file
    /// - Returns: Media metadata for message content
    func uploadFile(
        _ url: URL,
        for recipientId: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MediaMessageData {
        let filename = url.lastPathComponent
        Log.info("Uploading a file (.\(url.pathExtension.lowercased()))", category: "MediaManager")

        // A picked file is security-scoped; a forwarded one is the app's own temporary copy and
        // is not, which `startAccessingSecurityScopedResource` answers with false. Unreadable
        // files still fail, at the read below.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let originalData = try Data(contentsOf: url)
        let detectedMimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"

        // Sent as it is. Until 2026-09-30 a compressible document was DEFLATEd first, but no
        // field on the wire said so: receivers showed the compressed bytes (Android now guesses by
        // trying to inflate). Compression before encryption would also let the sealed size speak
        // for the contents.
        let uploadResult = try await Self.uploadWithRetry(
            data: originalData, mimeType: detectedMimeType, reuse: ForwardStaging.reuse(for: url, to: recipientId),
            onProgress: onProgress)
        Log.info("File uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        // A forward's copy has served its purpose; until now a failed upload could still retry it.
        ForwardStaging.discard(url)

        return MediaMessageData(
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: detectedMimeType,
            size: originalData.count,
            width: nil,
            height: nil,
            duration: nil,
            thumbnail: nil,
            hash: uploadResult.hash,
            filename: filename
        )
    }

    // MARK: - Voice message upload

    /// Upload an AAC/M4A voice recording.
    /// - Parameters:
    ///   - url: Local temp file URL (caller is responsible for deleting after this returns)
    ///   - duration: Recording duration in seconds
    ///   - waveform: ~100 normalized amplitude samples (0.0–1.0) for waveform display
    /// - Returns: `VoiceMessageContent` ready to be JSON-encoded as the message payload
    func uploadAudio(_ url: URL, duration: TimeInterval, waveform: [Float], for recipientId: String) async throws -> VoiceMessageContent {
        Log.info("Uploading voice message (duration \(Int(duration))s)", category: "MediaManager")
        let data = try Data(contentsOf: url)
        let uploadResult = try await Self.uploadWithRetry(
            data: data, mimeType: "audio/m4a", reuse: ForwardStaging.reuse(for: url, to: recipientId))
        ForwardStaging.discard(url)
        Log.info("Voice uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        return VoiceMessageContent(
            type: "voice",
            mediaId: uploadResult.mediaId,
            mediaUrl: uploadResult.mediaUrl,
            mediaKey: uploadResult.encryptionKey,
            mediaType: "audio/m4a",
            size: data.count,
            duration: duration,
            waveform: waveform,
            hash: uploadResult.hash
        )
    }

    /// Upload avatar image (profile sharing)
    /// - Parameter image: Avatar image to upload
    /// - Returns: Avatar upload result with raw encryption key
    func uploadAvatar(_ image: PlatformImage) async throws -> AvatarUploadResult {
        Log.info("Uploading avatar", category: "MediaManager")
        
        // Optimize avatar (resize + compress) using ImageHelper, then bring it to the one length
        // every avatar has on the wire (`AvatarPadding`).
        guard let avatarData = ImageHelper.prepareAvatarImage(image).map(AvatarPadding.padded) else {
            throw MediaManagerError.optimizationFailed
        }
        
        // One new object per contact the profile goes to (`ProfileShareViewModel`): never a reuse,
        // or the cache would hand every contact the same object again.
        let uploadResult = try await Self.uploadWithRetry(
                data: avatarData,
                mimeType: "image/jpeg",
                reuse: .freshObject
            )
        Log.info("Avatar uploaded: \(uploadResult.mediaId)", category: "MediaManager")
        
        return AvatarUploadResult(
            mediaUrl: uploadResult.mediaUrl,
            encryptionKey: uploadResult.encryptionKey,
            mediaId: uploadResult.mediaId,
            hash: uploadResult.hash
        )
    }
}
