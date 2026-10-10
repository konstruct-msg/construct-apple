//
//  HistoryBodyCodec.swift
//  Construct Messenger
//
//  A row from before CTM1 → the wire body oneof. Every other body crosses as bytes in the core
//  (`history_export_message`, decisions/history-projection-in-the-core.md); these rows exist only
//  on iOS, and step 4 of the store plan converts them.
//

import Foundation
import SwiftProtobuf

enum HistoryBodyCodec {

    // MARK: - Legacy

    /// Inverse of the display-path rehydration. Known JSON shapes go through the
    /// same parsers the bubbles use; anything else that is valid UTF-8 and not a
    /// typed JSON object becomes MessageContent{text}; the rest is unconvertible.
    static func liftLegacy(_ data: Data) -> Construct_Client_History_V1_HistoryMessage.OneOf_Body? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        if let voice = parseVoiceContent(from: text) {
            return .messageContent(MediaWireCodec.voiceMessageContent(from: voice))
        }
        if let media = parseMediaContent(from: text) {
            let items = media.mediaItems.map { dict in
                MediaMessageData(
                    mediaId: dict["mediaId"] as? String ?? "",
                    mediaUrl: dict["mediaUrl"] as? String ?? "",
                    mediaKey: (dict["mediaKey"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data(),
                    mediaType: dict["mediaType"] as? String ?? "application/octet-stream",
                    size: dict["size"] as? Int ?? 0,
                    width: dict["width"] as? Int,
                    height: dict["height"] as? Int,
                    duration: dict["duration"] as? Double,
                    thumbnail: nil,
                    hash: dict["hash"] as? String ?? "",
                    filename: dict["filename"] as? String,
                    blurhash: dict["blurhash"] as? String
                )
            }
            let wire = MediaWireCodec.albumContent(mediaList: items, caption: media.caption, quoted: nil)
            if case .mediaAlbum(let album)? = wire.content {
                return .mediaAlbum(album)
            }
            return .messageContent(wire)
        }
        if let file = try? JSONDecoder().decode(FileMessageContent.self, from: data),
           file.type == "file" {
            let items = file.files.map { entry in
                MediaMessageData(
                    mediaId: entry.mediaId,
                    mediaUrl: entry.mediaUrl,
                    mediaKey: entry.mediaKey,
                    mediaType: entry.mediaType,
                    size: entry.size,
                    width: nil,
                    height: nil,
                    duration: nil,
                    thumbnail: nil,
                    hash: entry.hash,
                    filename: entry.filename
                )
            }
            let wire = MediaWireCodec.fileAlbumContent(mediaList: items, caption: file.caption)
            if case .mediaAlbum(let album)? = wire.content {
                return .mediaAlbum(album)
            }
            return .messageContent(wire)
        }

        if isTypedJSONObject(text) {
            return nil
        }
        return .messageContent(textContent(text))
    }

    private static func textContent(_ s: String) -> Shared_Proto_Messaging_V1_MessageContent {
        var text = Shared_Proto_Messaging_V1_TextMessage()
        text.text = s
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.text = text
        return content
    }

    /// `{"type":…}` that is not media/voice/file — a control artifact or an
    /// unknown local shape. Not plain text.
    private static func isTypedJSONObject(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] is String
        else { return false }
        return true
    }
}
