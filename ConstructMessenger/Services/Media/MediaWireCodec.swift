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
            if let thumbnail = item.thumbnail, !thumbnail.isEmpty { m.thumbnail = thumbnail }
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

    /// Rebuild local storage payload after a caption edit (CTM1 album or legacy JSON string).
    static func editedCaptionPayload(storedPlaintext: Data, newCaption: String)
        -> (storagePayload: Data, wire: Shared_Proto_Messaging_V1_MessageContent, displayPreview: String)?
    {
        switch LocalMessagePayload.decode(storedPlaintext) {
        case .mediaAlbum(let body):
            guard var album = try? Shared_Proto_Messaging_V1_MediaAlbumMessage(serializedBytes: body) else {
                return nil
            }
            album.caption = newCaption
            let storage = LocalMessagePayload.encodeMediaAlbum(album)
            var wire = Shared_Proto_Messaging_V1_MessageContent()
            wire.mediaAlbum = album
            let preview = newCaption.isEmpty ? NSLocalizedString("photo", comment: "") : newCaption
            return (storage, wire, preview)
        case .legacyUTF8, .text:
            let localJSON = LocalMessagePayload.decode(storedPlaintext).displayString
            guard let edited = editedCaption(localJSON: localJSON, newCaption: newCaption) else { return nil }
            let preview = newCaption.isEmpty ? NSLocalizedString("photo", comment: "") : newCaption
            return (Data(edited.localJSON.utf8), edited.wire, preview)
        default:
            return nil
        }
    }

    @MainActor
    static func storeThumbnails(
        from album: Shared_Proto_Messaging_V1_MediaAlbumMessage,
        for messageId: String
    ) {
        for (index, item) in album.items.enumerated() where item.hasThumbnail && !item.thumbnail.isEmpty {
            MediaManager.shared.storeThumbnail(item.thumbnail, for: messageId, at: index)
        }
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

    // MARK: - Voice / file dual-read JSON (UI parsers)

    /// Encode app `VoiceMessageContent` as wire `MessageContent.voice` + CTM1 storage blob.
    /// `codec` carries `mime|mediaId|size` so mediaId survives the proto (no dedicated field).
    static func voiceMessageContent(from voice: VoiceMessageContent) -> Shared_Proto_Messaging_V1_MessageContent {
        var v = Shared_Proto_Messaging_V1_VoiceMessage()
        v.fileURL = voice.mediaUrl
        v.encryptionKey = voice.mediaKey
        v.fileHash = hexToData(voice.hash) ?? Data()
        v.durationMs = UInt32(max(0, voice.duration * 1000))
        v.waveform = voice.waveform.map { sample in
            UInt32(max(0, min(255, Int((sample * 255).rounded()))))
        }
        v.codec = "\(voice.mediaType)|\(voice.mediaId)|\(voice.size)"
        var content = Shared_Proto_Messaging_V1_MessageContent()
        content.voice = v
        return content
    }

    /// Rehydrate legacy voice JSON for `parseVoiceContent` / bubbles.
    static func voiceJSON(from voice: Shared_Proto_Messaging_V1_VoiceMessage) -> String? {
        let parts = voice.codec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let mediaType = parts.count > 0 && !parts[0].isEmpty ? parts[0] : "audio/m4a"
        let mediaId = parts.count > 1 ? parts[1] : ""
        let size = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        let content = VoiceMessageContent(
            type: "voice",
            mediaId: mediaId,
            mediaUrl: voice.fileURL,
            mediaKey: voice.encryptionKey,
            mediaType: mediaType,
            size: size,
            duration: Double(voice.durationMs) / 1000.0,
            waveform: voice.waveform.map { Float($0) / 255.0 },
            hash: dataToHex(voice.fileHash)
        )
        guard let data = try? JSONEncoder().encode(content),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Build wire MessageContent.mediaAlbum from file uploads (each file → MediaMessage).
    static func fileAlbumContent(
        mediaList: [MediaMessageData],
        caption: String
    ) -> Shared_Proto_Messaging_V1_MessageContent {
        albumContent(mediaList: mediaList, caption: caption, quoted: nil)
    }

    /// Legacy `{"type":"file",…}` for dual-read UI when stored as media album of documents.
    static func fileJSON(from album: Shared_Proto_Messaging_V1_MediaAlbumMessage) -> String? {
        let files: [[String: Any]] = album.items.map { m in
            var dict: [String: Any] = [
                "mediaId": m.mediaID,
                "mediaUrl": m.fileURL,
                "mediaKey": m.encryptionKey.base64EncodedString(),
                "mediaType": m.mimeType,
                "size": Int(m.fileSize),
                "hash": dataToHex(m.fileHash),
                "filename": m.hasFilename ? m.filename : "file",
                "compressed": false,
            ]
            return dict
        }
        guard !files.isEmpty else { return nil }
        let obj: [String: Any] = [
            "type": "file",
            "caption": album.hasCaption ? album.caption : "",
            "files": files,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Prefer album of non-image/video items as file JSON for dual-read parsers.
    static func looksLikeFileAlbum(_ album: Shared_Proto_Messaging_V1_MediaAlbumMessage) -> Bool {
        guard !album.items.isEmpty else { return false }
        return album.items.allSatisfy { item in
            let mime = item.mimeType.lowercased()
            return !mime.hasPrefix("image/") && !mime.hasPrefix("video/")
                && !mime.hasPrefix("audio/")
        }
    }
}
