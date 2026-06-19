//
//  MediaWireCodec.swift
//  Construct Messenger
//
//  Bridges media descriptors between the binary wire format and the local JSON the
//  views parse.
//
//  Wire (inside E2EE): `MessageContent.mediaAlbum` — protobuf, compact, with the AES
//  key as raw `bytes` (no base64, no JSON). This replaces stuffing a JSON string into
//  `TextMessage.text`.
//
//  Local (display): we re-serialize the received album back into the existing
//  `{"type":"media", ...}` JSON shape that `parseMediaContent` expects, so the view
//  layer and Core Data storage are unchanged. Old media (sent as JSON-in-TextMessage)
//  still works via the `.text` path — free dual-read fallback.
//

import Foundation

enum MediaWireCodec {

    // MARK: - Send: [MediaMessageData] → MessageContent(.mediaAlbum)

    static func albumContent(
        mediaList: [MediaMessageData],
        caption: String,
        quoted: Shared_Proto_Messaging_V1_QuotedMessage?
    ) -> Shared_Proto_Messaging_V1_MessageContent {
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = mediaList.map { item in
            var m = Shared_Proto_Messaging_V1_MediaMessage()
            m.mediaID = item.mediaId
            m.fileURL = item.mediaUrl
            m.encryptionKey = item.mediaKey
            m.fileHash = hexToData(item.hash) ?? Data()
            m.fileSize = UInt64(max(0, item.size))
            m.mimeType = item.mediaType
            m.mediaType = protoMediaType(for: item.mediaType)
            if let filename = item.filename { m.filename = filename }
            if let w = item.width, let h = item.height, w > 0, h > 0 {
                var dims = Shared_Proto_Messaging_V1_MediaDimensions()
                dims.width = UInt32(w)
                dims.height = UInt32(h)
                m.dimensions = dims
            }
            if let d = item.duration, d > 0 { m.durationMs = UInt32(d * 1000) }
            if let bh = item.blurhash, !bh.isEmpty { m.blurhash = bh }
            return m
        }
        if !caption.isEmpty { album.caption = caption }
        if let quoted { album.quoted = quoted }

        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.mediaAlbum = album
        return content
    }

    // MARK: - Edit: rebuild an album from stored local JSON with a new caption

    /// Rebuild a media message for a **caption edit**. Given the message's stored local media
    /// JSON (`{"type":"media",…}`) and a new caption, returns:
    /// - `localJSON`: the same payload with only the caption replaced (media items untouched,
    ///   lossless) — for display + local persistence;
    /// - `wire`: the binary `MessageContent.mediaAlbum` to encrypt as the edit payload.
    ///
    /// Editing must NOT replace the content with plain text (that destroys the attachment).
    /// Returns nil if `localJSON` is not a media payload (caller falls back to a text edit).
    static func editedCaption(localJSON: String?, newCaption: String)
        -> (localJSON: String, wire: Shared_Proto_Messaging_V1_MessageContent)?
    {
        guard let localJSON,
              let data = localJSON.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "media",
              let items = obj["media"] as? [[String: Any]], !items.isEmpty
        else { return nil }

        // New local JSON: replace only the caption, keep every media item field as-is.
        obj["caption"] = newCaption
        guard let newData = try? JSONSerialization.data(withJSONObject: obj),
              let newLocalJSON = String(data: newData, encoding: .utf8)
        else { return nil }

        // Reconstruct the wire album from the stored items. Only wire-relevant fields are
        // needed; thumbnail/filename/compressed are not carried on the album wire today.
        let mediaList: [MediaMessageData] = items.map { d in
            MediaMessageData(
                mediaId: d["mediaId"] as? String ?? "",
                mediaUrl: d["mediaUrl"] as? String ?? "",
                mediaKey: (d["mediaKey"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data(),
                mediaType: d["mediaType"] as? String ?? "application/octet-stream",
                size: d["size"] as? Int ?? 0,
                width: d["width"] as? Int,
                height: d["height"] as? Int,
                duration: d["duration"] as? Double,
                thumbnail: nil,
                hash: d["hash"] as? String ?? "",
                filename: d["filename"] as? String,
                compressed: nil,
                blurhash: d["blurhash"] as? String
            )
        }
        let wire = albumContent(mediaList: mediaList, caption: newCaption, quoted: nil)
        return (newLocalJSON, wire)
    }

    // MARK: - Receive: MediaAlbumMessage → media JSON (parseMediaContent shape)

    static func mediaJSON(from album: Shared_Proto_Messaging_V1_MediaAlbumMessage) -> String? {
        let items: [[String: Any]] = album.items.map { m in
            var dict: [String: Any] = [
                "mediaId": m.mediaID,
                "mediaUrl": m.fileURL,
                "mediaKey": m.encryptionKey.base64EncodedString(),
                "mediaType": m.mimeType,
                "size": Int(m.fileSize),
                "hash": dataToHex(m.fileHash),
            ]
            if m.hasDimensions {
                dict["width"] = Int(m.dimensions.width)
                dict["height"] = Int(m.dimensions.height)
            }
            if m.hasDurationMs { dict["duration"] = Double(m.durationMs) / 1000.0 }
            if m.hasBlurhash, !m.blurhash.isEmpty { dict["blurhash"] = m.blurhash }
            return dict
        }
        let obj: [String: Any] = [
            "type": "media",
            "caption": album.hasCaption ? album.caption : "",
            "media": items,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: - Helpers

    private static func protoMediaType(for mime: String) -> Shared_Proto_Messaging_V1_MediaType {
        let m = mime.lowercased()
        if m.hasPrefix("image/") { return m.contains("gif") ? .animated : .image }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("audio/") { return .audio }
        return .file
    }

    private static func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }

    private static func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
