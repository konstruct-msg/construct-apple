//
//  HistoryBodyCodec.swift
//  Construct Messenger
//
//  Wire oneof ↔ iOS CTM1 store form. store calls LocalMessagePayload; it
//  does not rewrite that mapping.
//

import Foundation
import SwiftProtobuf

enum HistoryBodyCodec {

    enum BodyDisposition: Equatable {
        case ok
        case unknownBody
        case malformed
    }

    /// Unset body with no unknown fields is malformed. Unset body plus unknown
    /// fields is a future oneof case — skip like an unknown record type.
    static func disposition(of message: Construct_Client_History_V1_HistoryMessage) -> BodyDisposition {
        if message.body != nil { return .ok }
        if message.unknownFields != SwiftProtobuf.UnknownStorage() { return .unknownBody }
        return .malformed
    }

    static func lift(stored: LocalMessagePayload) -> Construct_Client_History_V1_HistoryMessage.OneOf_Body? {
        switch stored {
        case .messageContent(let bytes):
            guard let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: bytes) else {
                return nil
            }
            return .messageContent(content)
        case .mediaAlbum(let bytes):
            guard let album = try? Shared_Proto_Messaging_V1_MediaAlbumMessage(serializedBytes: bytes) else {
                return nil
            }
            return .mediaAlbum(album)
        case .profileBinary(let data):
            return .profileShare(data)
        case .text(let s):
            return .messageContent(textContent(s))
        case .legacyUTF8(let data):
            return liftLegacy(data)
        }
    }

    static func store(_ body: Construct_Client_History_V1_HistoryMessage.OneOf_Body) throws -> Data {
        switch body {
        case .messageContent(let content):
            return LocalMessagePayload.storagePayload(forWireContent: content)
        case .mediaAlbum(let album):
            return LocalMessagePayload.encodeMediaAlbum(album)
        case .profileShare(let data):
            return LocalMessagePayload.encodeProfileBinary(data)
        }
    }

    // MARK: - Legacy

    /// Inverse of the display-path rehydration. Known JSON shapes go through the
    /// same parsers the bubbles use; anything else that is valid UTF-8 and not a
    /// typed JSON object becomes MessageContent{text}; the rest is unconvertible.
    private static func liftLegacy(_ data: Data) -> Construct_Client_History_V1_HistoryMessage.OneOf_Body? {
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
                    compressed: nil,
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
                    filename: entry.filename,
                    compressed: nil
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
