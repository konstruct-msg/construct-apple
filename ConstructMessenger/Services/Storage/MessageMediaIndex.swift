//
//  MessageMediaIndex.swift
//  Construct Messenger
//
//  What media a stored message holds, for the store's media index: the chat gallery and the
//  storage screen read it (construct-docs todo 327, decisions/chat-media-gallery-storage-backup.md).
//  The core does not read albums, so the client fills the index, as it fills `message_search`.
//

import Foundation
import SwiftProtobuf   // Shared_Proto_* init(serializedBytes:) — explicit under #MemberImportVisibility

enum MessageMediaIndex {
    /// The index entries of a message whose body is `body`, or nil when the body cannot hold media
    /// (a plain text, a profile, a pre-CTM1 row) and the index is not asked about it.
    ///
    /// Empty — not nil — for a message content that turns out to be a text or a sticker: the store
    /// lists every unindexed album and message content (`unindexed_media_messages`) until it is
    /// indexed, with no entries too.
    static func entries(for body: Data) -> [LocalMediaEntry]? {
        switch LocalMessagePayload.decode(body) {
        case .mediaAlbum(let bytes):
            guard let album = try? Shared_Proto_Messaging_V1_MediaAlbumMessage(serializedBytes: bytes) else {
                return []
            }
            return entries(of: album.items)
        case .messageContent(let bytes):
            guard let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: bytes) else {
                return []
            }
            switch content.content {
            case .mediaAlbum(let album): return entries(of: album.items)
            case .media(let item): return entries(of: [item])
            case .voice(let voice):
                let ref = MediaWireCodec.voiceMediaRef(from: voice)
                guard !ref.mediaId.isEmpty else { return [] }
                return [LocalMediaEntry(item: 0, mediaId: ref.mediaId, kind: .voice, byteSize: Int64(ref.size))]
            default: return []
            }
        case .text, .profileBinary, .legacyUTF8:
            return nil
        }
    }

    /// The kind the gallery files an item under: by its MIME type, a round video by presentation.
    /// What is neither picture nor video is a file — the rule `MediaWireCodec.looksLikeFileAlbum`
    /// applies to a whole album, here per item.
    static func kind(mime: String, presentation: Shared_Proto_Messaging_V1_MediaPresentation) -> LocalMediaKind {
        let mime = mime.lowercased()
        if mime.hasPrefix("video/") { return presentation == .videoNote ? .videoNote : .video }
        if mime == "image/gif" { return .animation }
        if mime.hasPrefix("image/") { return .photo }
        return .file
    }

    /// An item's position in the album is its `item`, so the gallery opens the bubble's own item;
    /// one with no media id has no file to show and is left out, the positions of the rest kept.
    private static func entries(of items: [Shared_Proto_Messaging_V1_MediaMessage]) -> [LocalMediaEntry] {
        items.enumerated().compactMap { index, item in
            guard !item.mediaID.isEmpty else { return nil }
            return LocalMediaEntry(
                item: UInt32(index),
                mediaId: item.mediaID,
                kind: kind(mime: item.mimeType, presentation: item.presentation),
                byteSize: Int64(clamping: item.fileSize)
            )
        }
    }
}
