//
//  HistoryAccountID.swift
//  Construct Messenger
//
//  ServerUserId as 16 raw UUID bytes (CTH1 proto) ↔ dashed UUID (Core Data).
//  No Core Data, no CryptoKit.
//

import Foundation

enum HistoryAccountID {

    static func dashed(_ raw: Data) -> String? {
        guard raw.count == 16 else { return nil }
        let b = [UInt8](raw)
        let uuid = UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
        return uuid.uuidString.lowercased()
    }

    static func raw(_ dashed: String) -> Data? {
        guard let uuid = UUID(uuidString: dashed) else { return nil }
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    /// media_id values referenced by a lifted body (album items, media, voice).
    static func mediaRefs(
        in body: Construct_Client_History_V1_HistoryMessage.OneOf_Body
    ) -> [(id: String, mime: String)] {
        switch body {
        case .mediaAlbum(let album):
            return album.items.compactMap(mediaRef(from:))
        case .messageContent(let content):
            return mediaRefs(in: content)
        case .profileShare:
            return []
        }
    }

    static func mediaRefs(in content: Shared_Proto_Messaging_V1_MessageContent) -> [(id: String, mime: String)] {
        switch content.content {
        case .media(let media):
            return mediaRef(from: media).map { [$0] } ?? []
        case .voice(let voice):
            let parts = voice.codec.split(separator: "|", omittingEmptySubsequences: false)
            let mime = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? "audio/m4a"
            let id = parts.count > 1 ? String(parts[1]) : ""
            return id.isEmpty ? [] : [(id, mime)]
        case .mediaAlbum(let album):
            return album.items.compactMap(mediaRef(from:))
        default:
            return []
        }
    }

    private static func mediaRef(
        from media: Shared_Proto_Messaging_V1_MediaMessage
    ) -> (id: String, mime: String)? {
        guard !media.mediaID.isEmpty else { return nil }
        let mime = media.mimeType.isEmpty ? mimeFallback(media.mediaType) : media.mimeType
        return (media.mediaID, mime)
    }

    private static func mimeFallback(_ type: Shared_Proto_Messaging_V1_MediaType) -> String {
        switch type {
        case .image, .animated: return "image/jpeg"
        case .video: return "video/mp4"
        case .audio: return "audio/m4a"
        case .file, .sticker, .unspecified, .UNRECOGNIZED: return "application/octet-stream"
        }
    }
}
