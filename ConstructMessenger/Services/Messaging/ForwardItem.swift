//
//  ForwardItem.swift
//  Construct Messenger
//
//  What a forward sends: the content of a message, and nothing about where it came from.
//
//  Owner's rule (2026-10-13): nobody may ever learn whom a forwarded message is from — that is a
//  leak. So a forward is an ordinary send of the same content. It carries no author, no
//  "forwarded" mark, no reply or quote of the original and no time, and its media is uploaded
//  again under a fresh key (`MediaUploadReuse.freshObject`): the original's media object is never
//  referenced, because a second chat fetching the same object would tie the two messages together
//  for the server.
//
//  The references kept here (`ForwardMedia`) only locate the local copy of the bytes. None of them
//  goes into the message that is sent.
//

import Foundation

struct ForwardMedia: Equatable, Sendable {
    let mediaId: String
    let mediaUrl: String
    let mediaKey: Data
    let mimeType: String
    let filename: String?
    let duration: TimeInterval?
    let presentation: MediaPresentation?
}

enum ForwardItem: Equatable, Sendable {
    case text(String)
    /// Photos and videos, a video note among them; the caption is content and goes with them.
    case media([ForwardMedia], caption: String)
    case files([ForwardMedia], caption: String)
    case voice(ForwardMedia, duration: TimeInterval, waveform: [Float])
    case sticker(StickerReference)

    /// The content of a stored message, read the way its bubble reads it. Nil for what is not
    /// forwarded: a shared profile (whose meaning is the sharer), and anything with nothing to send.
    static func content(legacyBody: String, plainText: String?, sticker: StickerReference?) -> ForwardItem? {
        if let sticker { return .sticker(sticker) }
        if MessageBubbleContentParsing.parseProfileMessage(legacyBody) != nil { return nil }
        if let media = MessageBubbleContentParsing.parseMediaMessage(legacyBody) {
            let items = media.mediaItems.compactMap(Self.media(from:))
            guard items.count == media.mediaItems.count else { return nil }
            return .media(items, caption: media.caption)
        }
        if let file = MessageBubbleContentParsing.parseFileMessage(legacyBody) {
            let items = file.files.map {
                ForwardMedia(mediaId: $0.mediaId, mediaUrl: $0.mediaUrl, mediaKey: $0.mediaKey,
                             mimeType: $0.mediaType, filename: $0.filename, duration: nil, presentation: nil)
            }
            guard !items.isEmpty, items.allSatisfy({ !$0.mediaId.isEmpty && !$0.mediaKey.isEmpty }) else { return nil }
            return .files(items, caption: file.caption)
        }
        if let voice = MessageBubbleContentParsing.parseVoiceMessage(legacyBody) {
            guard !voice.mediaId.isEmpty, !voice.mediaKey.isEmpty else { return nil }
            let audio = ForwardMedia(mediaId: voice.mediaId, mediaUrl: voice.mediaUrl, mediaKey: voice.mediaKey,
                                     mimeType: voice.mediaType, filename: nil, duration: voice.duration,
                                     presentation: nil)
            return .voice(audio, duration: voice.duration, waveform: voice.waveform)
        }
        guard let text = plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return .text(text)
    }

    /// The forwardable content of `rows`, in transcript order whatever order they were picked in.
    static func content(of rows: [TranscriptRow]) -> [ForwardItem] {
        rows.filter(isForwardable)
            .sorted { $0.orderKey < $1.orderKey }
            .compactMap { content(legacyBody: $0.legacyBody, plainText: $0.plainText, sticker: $0.stickerReference) }
    }

    /// A row a person wrote or sent, whose content is here to read.
    static func isForwardable(_ row: TranscriptRow) -> Bool {
        !row.isControlArtifact && !row.isServiceArtifact && row.hasDecryptedContent
            && row.fromUserId != "SYSTEM"
    }

    private static func media(from item: [String: Any]) -> ForwardMedia? {
        guard let mediaId = item["mediaId"] as? String, !mediaId.isEmpty,
              let keyText = item["mediaKey"] as? String, let key = Data(base64Encoded: keyText), !key.isEmpty
        else { return nil }
        return ForwardMedia(
            mediaId: mediaId,
            mediaUrl: item["mediaUrl"] as? String ?? "",
            mediaKey: key,
            mimeType: item["mediaType"] as? String ?? "image/jpeg",
            filename: item["filename"] as? String,
            duration: item["duration"] as? Double,
            presentation: MediaPresentation.of(item)
        )
    }
}
