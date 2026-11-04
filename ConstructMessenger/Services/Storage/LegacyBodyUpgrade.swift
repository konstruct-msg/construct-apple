//
//  LegacyBodyUpgrade.swift
//  Construct Messenger
//
//  Media rows from before CTM1 (2026-07-26) hold the JSON the bubbles once read, with each media
//  key as base64. The move to `construct.db` (`LocalStoreImport`) copied their bodies as they
//  were, though the store plan meant step 4 to convert them. This converts them once, in the
//  store, to the CTM1 body a row written today holds.
//
//  Only media, file and voice JSON: plain-text rows hold no key, and an upload placeholder is
//  JSON on purpose (`UploadPlaceholderBody`) and has no key, so it never reads the same. A row
//  converts only if what the bubbles read from it is the same afterwards (`readsTheSame`); a
//  media row that would lose something stays as it is and is counted.
//

import Foundation

enum LegacyBodyUpgrade {

    /// Set in the store once a pass has read every row. A later change to what converts takes a
    /// new key.
    static let doneKey = "construct.localStore.legacyMediaBodiesConverted.v1"
    static let page = 200

    struct Counts: Equatable {
        var converted = 0
        /// Media JSON that would not read the same as CTM1: left as it was.
        var kept = 0
    }

    // MARK: - One body

    /// The CTM1 body for a pre-CTM1 media, file or voice body; nil for anything else, and for one
    /// whose conversion would change what is shown.
    static func converted(_ body: Data) -> Data? {
        guard case .legacyUTF8(let data) = LocalMessagePayload.decode(body),
              let text = String(data: data, encoding: .utf8),
              isMediaShape(text),
              let lifted = HistoryBodyCodec.liftLegacy(data)
        else { return nil }
        let ctm1: Data
        switch lifted {
        case .mediaAlbum(let album): ctm1 = LocalMessagePayload.encodeMediaAlbum(album)
        case .messageContent(let content): ctm1 = LocalMessagePayload.storagePayload(forWireContent: content)
        default: return nil
        }
        return readsTheSame(legacy: text, converted: LocalMessagePayload.decode(ctm1).displayString) ? ctm1 : nil
    }

    /// Whether `text` is one of the three JSON shapes that carry a media key.
    static func isMediaShape(_ text: String) -> Bool {
        parseVoiceContent(from: text) != nil
            || parseMediaContent(from: text) != nil
            || MessageBubbleContentParsing.parseFileMessage(text) != nil
    }

    /// What the bubbles, the gallery and forwarding read from each body is equal. The proto keeps
    /// durations in milliseconds and waveform samples in 1/255 steps, so those compare within one
    /// step; the hash is hex either way, in either case.
    static func readsTheSame(legacy: String, converted: String) -> Bool {
        if let a = parseVoiceContent(from: legacy) {
            guard let b = parseVoiceContent(from: converted) else { return false }
            return !a.mediaKey.isEmpty && a.mediaId == b.mediaId && a.mediaUrl == b.mediaUrl && a.mediaKey == b.mediaKey
                && a.mediaType == b.mediaType && a.size == b.size && a.hash.lowercased() == b.hash.lowercased()
                && abs(a.duration - b.duration) < 0.001
                && a.waveform.count == b.waveform.count
                && zip(a.waveform, b.waveform).allSatisfy { abs($0 - $1) <= 1.0 / 255 }
        }
        if let a = parseMediaContent(from: legacy) {
            guard let b = parseMediaContent(from: converted),
                  a.caption == b.caption, a.mediaItems.count == b.mediaItems.count
            else { return false }
            return zip(a.mediaItems, b.mediaItems).allSatisfy(sameMediaItem)
        }
        if let a = MessageBubbleContentParsing.parseFileMessage(legacy) {
            guard let b = MessageBubbleContentParsing.parseFileMessage(converted),
                  a.caption == b.caption, a.files.count == b.files.count
            else { return false }
            return zip(a.files, b.files).allSatisfy { x, y in
                !x.mediaKey.isEmpty && x.mediaKey == y.mediaKey && x.mediaId == y.mediaId
                    && x.mediaUrl == y.mediaUrl && x.mediaType == y.mediaType && x.size == y.size
                    && x.hash.lowercased() == y.hash.lowercased() && x.filename == y.filename
            }
        }
        return false
    }

    private static func sameMediaItem(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        func key(_ d: [String: Any]) -> Data? { (d["mediaKey"] as? String).flatMap { Data(base64Encoded: $0) } }
        func string(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
        // Zero is how the proto says "none" for a dimension or a duration.
        func positive(_ d: [String: Any], _ k: String) -> Int { max(0, d[k] as? Int ?? 0) }
        func seconds(_ d: [String: Any]) -> Double { max(0, d["duration"] as? Double ?? 0) }
        guard let keyA = key(a), !keyA.isEmpty, keyA == key(b) else { return false }
        return string(a, "mediaId") == string(b, "mediaId")
            && string(a, "mediaUrl") == string(b, "mediaUrl")
            && (a["mediaType"] as? String ?? "application/octet-stream") == string(b, "mediaType")
            && (a["size"] as? Int ?? 0) == (b["size"] as? Int ?? 0)
            && string(a, "hash").lowercased() == string(b, "hash").lowercased()
            && positive(a, "width") == positive(b, "width")
            && positive(a, "height") == positive(b, "height")
            && abs(seconds(a) - seconds(b)) < 0.001
            && string(a, "blurhash") == string(b, "blurhash")
            && string(a, "filename") == string(b, "filename")
            && MediaPresentation.of(a) == MediaPresentation.of(b)
    }

    // MARK: - The store

    /// Converts every legacy media body in `messages`, then sets `doneKey` in `keyValue`; nothing
    /// once it is set. A read that fails stops the pass before the key, so the next open runs it
    /// again. Run where nothing else writes meanwhile: the store's open, under its lock.
    @discardableResult
    static func runIfDue(messages: any MessageStore, keyValue: any KeyValueStore) throws -> Counts? {
        guard try keyValue.get(doneKey) == nil else { return nil }
        var counts = Counts()
        var cursor: (orderKey: String, id: String)?
        while true {
            let rows = try messages.allMessages(after: cursor, limit: page)
            guard let last = rows.last else { break }
            for row in rows {
                if let body = converted(row.body) {
                    try messages.setBody(row.id, body: body, searchText: LocalMessagePayload.decode(body).plainText)
                    counts.converted += 1
                } else if case .legacyUTF8(let data) = LocalMessagePayload.decode(row.body),
                          let text = String(data: data, encoding: .utf8),
                          isMediaShape(text), !UploadPlaceholderBody.isSentinel(text) {
                    counts.kept += 1
                }
            }
            cursor = (last.orderKey, last.id)
        }
        try keyValue.put(doneKey, Data([1]))
        return counts
    }
}
