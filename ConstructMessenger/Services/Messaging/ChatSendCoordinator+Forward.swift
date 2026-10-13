//
//  ChatSendCoordinator+Forward.swift
//  Construct Messenger
//
//  A forward, as the destination chat sends it: each item through the ordinary send for its
//  kind, built from the local copy of its bytes, uploaded as a new object. See `ForwardItem` for
//  what is carried and what is not.
//

import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension ChatSendCoordinator {

    enum ForwardFailure: Error, Equatable {
        /// Neither this device nor the server has the bytes any more (the server keeps media for
        /// seven days from upload).
        case contentGone
    }

    /// Sends `items` in order. A media item whose bytes cannot be found is skipped and reported;
    /// the rest still go.
    @discardableResult
    func forward(_ items: [ForwardItem]) async -> [ForwardFailure] {
        var failures: [ForwardFailure] = []
        for item in items {
            do {
                try await send(item)
            } catch {
                Log.error("Forward: an item could not be prepared — \(error)", category: "Forward")
                failures.append(.contentGone)
            }
        }
        return failures
    }

    private func send(_ item: ForwardItem) async throws {
        switch item {
        case .text(let text):
            sendMessage(text: text)
        case .sticker(let reference):
            sendSticker(reference)
        case .media(let media, let caption):
            var attachments: [MediaAttachment] = []
            for entry in media {
                attachments.append(try await attachment(for: entry))
            }
            sendMessage(text: caption, attachments: attachments)
        case .files(let files, let caption):
            var urls: [URL] = []
            for entry in files {
                urls.append(try await stagedCopy(of: entry, named: entry.filename ?? "file"))
            }
            sendMessage(text: caption, fileURLs: urls)
        case .voice(let audio, let duration, let waveform):
            let url = try await stagedCopy(of: audio, named: "voice.m4a")
            sendVoiceMessage(url: url, duration: duration, waveform: waveform)
        }
    }

    private func bytes(of entry: ForwardMedia) async throws -> Data {
        do {
            return try await MediaManager.shared.downloadAndDecryptMedia(
                mediaId: entry.mediaId, mediaUrl: entry.mediaUrl, mediaKey: entry.mediaKey)
        } catch {
            throw ForwardFailure.contentGone
        }
    }

    private func stagedCopy(of entry: ForwardMedia, named filename: String) async throws -> URL {
        let data = try await bytes(of: entry)
        let url = try ForwardStaging.newFileURL(named: filename)
        try data.write(to: url, options: .completeFileProtection)
        return url
    }

    private func attachment(for entry: ForwardMedia) async throws -> MediaAttachment {
        if entry.mimeType.lowercased().hasPrefix("video/") {
            let url = try await stagedCopy(of: entry, named: "video.mp4")
            var attachment = MediaAttachment(
                videoURL: url, poster: nil, duration: entry.duration, presentation: entry.presentation)
            attachment.isForwarded = true
            return attachment
        }
        let data = try await bytes(of: entry)
        // Sent as the bytes it arrived as — compressing again would only lose more of it.
        var attachment = MediaAttachment(
            originalData: data, mimeType: entry.mimeType, displayImage: PlatformImage(data: data), quality: .original)
        attachment.isForwarded = true
        return attachment
    }
}
