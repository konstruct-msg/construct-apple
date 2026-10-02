import Foundation
import SwiftProtobuf

struct ChunkedMessagePlan {
    let messageId: UUID
    let payloads: [Data]
    let originalLength: Int

    /// One frame holding the whole payload — a control carrier, never split. The frame is
    /// `ChunkedMessageCodec.frameWhole`; this is only the shape the pipeline sends.
    static func whole(_ payload: Data, contentType: UInt8, messageId: UUID) -> ChunkedMessagePlan {
        ChunkedMessagePlan(
            messageId: messageId,
            payloads: [ChunkedMessageCodec.frameWhole(payload, contentType: contentType, messageId: messageId)],
            originalLength: payload.count
        )
    }
}

final class ChunkedMessageSender {
    static let shared = ChunkedMessageSender()

    private init() {}

    func buildPlan(plaintext: Data, messageId: UUID, contentType: UInt8 = 1) -> ChunkedMessagePlan {
        let payloads = ChunkedMessageCodec.encodeChunks(
            plaintext: plaintext, messageId: messageId, contentType: contentType
        )
        return ChunkedMessagePlan(messageId: messageId, payloads: payloads, originalLength: plaintext.count)
    }

    // Sending lives in `OutboundMessagePipeline.sendToRecipientDevices` — one copy per device of
    // the recipient. The per-account `sendChunks` that was here encrypted to whichever device the
    // pinned key named and left the rest to a fan-out with different guarantees; see the pipeline.
}

final class ChunkedMessageReassembler {

    /// Shared instance used by both MessageRouter (live stream) and
    /// BackgroundFetchManager (silent-push path).  Both paths run their
    /// reassembler interactions on the main thread, so no extra locking is needed.
    static let shared = ChunkedMessageReassembler()

    /// Partial reassembly lives in `PendingReassemblyStore` — on disk, encrypted, surviving a
    /// restart. There is deliberately no in-memory map here any more: a chunk decrypted in this
    /// process consumes its ratchet key, so a redelivery after a kill cannot be decrypted again
    /// and an in-memory-only partial was simply lost. See decisions/durable-chunk-reassembly.md.
    private let store = PendingReassemblyStore.shared

    /// Decode one decrypted payload.
    ///
    /// `envelopeId` is the transport id that carried these bytes. It is recorded with the partial
    /// so the caller can mark it processed the moment the bytes are durable — an intermediate
    /// chunk that is never marked is what let the same ids loop through redelivery.
    ///
    /// `now` is a parameter only so expiry is testable without waiting out the retention window.
    func process(data: Data, envelopeId: String, now: Date = Date()) -> ChunkedMessageResult {
        switch assemble(data: data, envelopeId: envelopeId, now: now) {
        case .complete(let assembled, let e2eMessageId):
            return decodeAssembled(assembled, e2eMessageId: e2eMessageId)
        case .notFramed(let raw):
            return decodeRaw(raw)
        case .incomplete:
            return .incomplete
        case .invalid(let reason):
            return .invalid(reason)
        }
    }

    /// Reassemble the KNST framing without decoding what it carries.
    ///
    /// `process` is this plus a decode, and is what every ordinary content type uses. SENDER_SYNC
    /// needs the two apart: a routing header precedes its content inside the ciphertext (see
    /// `SenderSyncRouting`), and it has to come off after reassembly — a multi-chunk sync carries
    /// it only in the first chunk's share of the stream — but before the content decoder, which
    /// would otherwise be handed 20 bytes of header and reject the whole message.
    ///
    /// Splitting rather than special-casing: the framing logic stays in one place and `process`
    /// keeps calling it, so a sender-sync stream and an ordinary one cannot drift apart in how
    /// they are reassembled.
    func assemble(data: Data, envelopeId: String, now: Date = Date()) -> ChunkedAssembly {
        // Sweep on every decrypted message, not only on chunked ones: a stalled reassembly is
        // most likely to be noticed while ordinary traffic keeps flowing from other peers.
        store.sweepExpired(now: now)

        // A KNST frame, as the core reads it; anything else is a direct proto or legacy text.
        guard let parsed = ChunkedMessageCodec.parseChunk(data: data) else { return .notFramed(data) }
        return assembleKnstChunk(parsed, envelopeId: envelopeId, now: now)
    }

    private func assembleKnstChunk(
        _ parsed: ChunkedMessageCodec.ParsedChunk,
        envelopeId: String,
        now: Date
    ) -> ChunkedAssembly {
        if parsed.totalChunks == 1 {
            let trimmed = parsed.payload.prefix(parsed.plaintextLength)
            return .complete(Data(trimmed), e2eMessageId: Self.e2eId(from: parsed.messageId))
        }
        if parsed.totalChunks > ChunkedDeliveryConfig.maxChunks {
            return .invalid("total_chunks exceeds max")
        }

        guard let complete = store.put(
            messageId: parsed.messageId,
            chunkIndex: parsed.chunkIndex,
            totalChunks: parsed.totalChunks,
            plaintextLength: parsed.plaintextLength,
            contentType: parsed.contentType,
            payload: parsed.payload,
            envelopeId: envelopeId,
            now: now
        ) else {
            return .incomplete
        }

        guard let assembled = complete.assembled() else {
            store.remove(messageId: parsed.messageId)
            return .invalid("Plaintext length exceeds assembled size")
        }
        store.remove(messageId: parsed.messageId)
        return .complete(assembled, e2eMessageId: Self.e2eId(from: parsed.messageId))
    }

    /// Normalize a KNST-header UUID to the row-id format (lowercased). Rejects the all-zero
    /// UUID that `toUUIDBytes()` yields for malformed headers.
    private static func e2eId(from uuid: UUID) -> String? {
        let id = uuid.uuidString.lowercased()
        return id == "00000000-0000-0000-0000-000000000000" ? nil : id
    }

    /// Decode reassembled plaintext into a message. Internal because SENDER_SYNC calls it itself,
    /// after taking its routing header off what `assemble` returned.
    func decodeAssembled(_ data: Data, e2eMessageId: String?) -> ChunkedMessageResult {
        if let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: data),
           content.content != nil
        {
            if let reaction = Self.reaction(from: content) {
                return reaction
            }
            if case .edit(let editMsg) = content.content {
                return .edit(targetMessageID: editMsg.targetMessageID, newText: editMsg.newText, newMedia: editMsg.newMedia)
            }
            if let rejected = Self.rejectedSticker(in: content) {
                return rejected
            }
            let (text, quoted, mediaAlbum) = extract(content)
            let storage = LocalMessagePayload.storagePayload(forWireContent: content)
            return .assembled(
                text: text,
                quoted: quoted,
                e2eMessageId: e2eMessageId,
                mediaAlbum: mediaAlbum,
                storagePayload: storage
            )
        }
        // Binary profile share before the UTF-8 fallback — it's a more specific, structured format,
        // and must surface as a profile (not a "__PROFILE_BINARY__" placeholder string).
        if ProfileShareData.fromBinaryData(data) != nil {
            return .profile(data)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.isEmpty
                ? .invalid("empty plaintext")
                : .assembled(text: text, quoted: nil, e2eMessageId: e2eMessageId, mediaAlbum: nil, storagePayload: LocalMessagePayload.encodeText(text))
        }
        return .invalid("non-decodable binary (\(data.count) bytes)")
    }

    private func decodeRaw(_ data: Data) -> ChunkedMessageResult {
        // Try proto first (single-message delivery without KNST framing)
        if let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: data),
           content.content != nil
        {
            if let reaction = Self.reaction(from: content) {
                return reaction
            }
            if case .edit(let editMsg) = content.content {
                return .edit(targetMessageID: editMsg.targetMessageID, newText: editMsg.newText, newMedia: editMsg.newMedia)
            }
            if let rejected = Self.rejectedSticker(in: content) {
                return rejected
            }
            let (text, quoted, mediaAlbum) = extract(content)
            return .assembled(
                text: text,
                quoted: quoted,
                e2eMessageId: nil,
                mediaAlbum: mediaAlbum,
                storagePayload: LocalMessagePayload.storagePayload(forWireContent: content)
            )
        }
        // Binary profile share (new format, no JSON) — check before the UTF-8 fallback so it
        // surfaces as a profile, not a "__PROFILE_BINARY__" placeholder text message.
        if ProfileShareData.fromBinaryData(data) != nil {
            return .profile(data)
        }
        // END_SESSION marker: the one control payload that is a magic string rather than a frame,
        // because it has no ciphertext to carry a frame in.
        if SessionControlCodec.isEndSessionMarker(data) {
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return .legacy(text)
            }
            return .invalid("control magic not valid UTF-8")
        }
        // Legacy plain-text chat messages
        if let text = String(data: data, encoding: .utf8) {
            return text.isEmpty ? .invalid("empty plaintext") : .legacy(text)
        }
        return .invalid("non-decodable binary (\(data.count) bytes)")
    }

    /// Reaction payloads must not fall through to `.assembled` (empty text → blank bubble).
    /// `timestampMs` is 0 from a peer that predates the field, which the reducer reads as such.
    private static func reaction(
        from content: Shared_Proto_Messaging_V1_MessageContent
    ) -> ChunkedMessageResult? {
        guard case .reaction(let msg) = content.content else { return nil }
        return .reaction(
            targetMessageID: msg.targetMessageID,
            emoji: msg.emoji,
            action: msg.action,
            timestampMs: msg.timestampMs
        )
    }

    /// A sticker whose reference fails the cross-client rules is corrupt content and is refused
    /// here, before anything is persisted — the alternative is a row that renders as nothing and
    /// cannot be told from a message that arrived empty.
    private static func rejectedSticker(
        in content: Shared_Proto_Messaging_V1_MessageContent
    ) -> ChunkedMessageResult? {
        guard case .sticker(let wire) = content.content, StickerReference(wire: wire) == nil else {
            return nil
        }
        return .invalid("sticker reference fails validation (pack_id \(wire.packID.count) bytes, emoji \(wire.emoji.utf8.count) bytes)")
    }

    private func extract(_ content: Shared_Proto_Messaging_V1_MessageContent)
        -> (String, Shared_Proto_Messaging_V1_QuotedMessage?, Shared_Proto_Messaging_V1_MediaAlbumMessage?)
    {
        switch content.content {
        case .text(let msg):
            return (msg.text, msg.hasQuoted ? msg.quoted : nil, nil)
        case .mediaAlbum(let album):
            if MediaWireCodec.looksLikeFileAlbum(album) {
                return (MediaWireCodec.fileJSON(from: album) ?? "", album.hasQuoted ? album.quoted : nil, album)
            }
            return (MediaWireCodec.mediaJSON(from: album) ?? "", album.hasQuoted ? album.quoted : nil, album)
        case .media(let m):
            var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
            album.items = [m]
            if m.hasCaption { album.caption = m.caption }
            return (MediaWireCodec.mediaJSON(from: album) ?? "", nil, album)
        case .voice(let v):
            return (MediaWireCodec.voiceJSON(from: v) ?? "", nil, nil)
        default:
            return ("", nil, nil)
        }
    }

    // `process(decryptedText:)` and its second pending map were removed on 2026-08-03. The
    // `KNST1:<base64>` text framing has no producer anywhere in the app — `encodeChunks` has
    // emitted binary frames throughout — so the path was unreachable, and its private copy of the
    // pending map was a second store of the one fact `PendingReassemblyStore` now owns.

    /// Expiry moved into `PendingReassemblyStore.sweepExpired` on 2026-08-03, together with the
    /// state it acts on. It reports the same way — ERROR naming the message, how many chunks of
    /// how many arrived and which indices are missing, plus `chunkReassemblyExpired` — but the
    /// window is now the store's 24 h retention rather than 60 s: the point of the durable copy is
    /// to outlive a relaunch, and a one-minute expiry would have thrown it away first.
    ///
    /// Test seam kept here for callers that drive expiry directly.
    func cleanupExpired(now: Date = Date()) {
        store.sweepExpired(now: now)
    }
}

/// The framing layer's answer, before anything looks at what was carried.
enum ChunkedAssembly {
    /// Every chunk is in. `e2eMessageId` is the sender's message id from the KNST header.
    case complete(Data, e2eMessageId: String?)
    /// A chunk landed and more are outstanding.
    case incomplete
    /// Not a KNST frame at all — a direct proto or a legacy plain-text payload.
    case notFramed(Data)
    case invalid(String)
}

enum ChunkedMessageResult {
    /// Successfully decoded message (KNST chunked or direct proto).
    /// `quoted` is non-nil when the sender embedded a reply reference in the proto plaintext.
    /// `e2eMessageId` is the sender's message id from the encrypted KNST header — the canonical
    /// end-to-end identity of the message. It must be used as the stored row id so that
    /// cross-device references (edits, E2E receipts, reply targets) keep working when the
    /// server reassigns envelope ids on the sealed-sender path. nil for legacy/raw payloads.
    case assembled(
        text: String,
        quoted: Shared_Proto_Messaging_V1_QuotedMessage?,
        e2eMessageId: String?,
        mediaAlbum: Shared_Proto_Messaging_V1_MediaAlbumMessage?,
        /// CTM1 (or nil for pure legacy string) bytes for `applyStoredEncryption(plaintextData:)`.
        storagePayload: Data?
    )
    /// Non-KNST data decoded as plain UTF-8 (session control strings, legacy messages).
    case legacy(String)
    /// Assembled binary profile-share payload (raw bytes; decode with `ProfileShareData.fromBinaryData`).
    /// Must NOT be rendered as text — the caller turns it into a profile bubble.
    case profile(Data)
    case incomplete
    case invalid(String)
    /// Modern edit inside MessageContent.
    case edit(targetMessageID: String, newText: Shared_Proto_Messaging_V1_TextMessage, newMedia: Shared_Proto_Messaging_V1_MediaMessage)
    /// Emoji reaction inside MessageContent. Never a chat row — apply to the target, ACK.
    /// `timestampMs` is field 4 (`ReactionWire`); 0 means a pre-field peer.
    case reaction(
        targetMessageID: String,
        emoji: String,
        action: Shared_Proto_Messaging_V1_ReactionAction,
        timestampMs: Int64
    )
}

enum ChunkedMessageCodec {
    static let legacyPrefix = "KNST1:"
    private static let prefix = legacyPrefix

    struct ParsedChunk {
        let messageId: UUID
        let chunkIndex: UInt16
        let totalChunks: UInt16
        let plaintextLength: Int
        let payload: Data
        /// Content type recovered from header byte 5 — the authority for what this plaintext is.
        /// Rides inside the ciphertext, so unlike `SealedInner.content_type` the server cannot
        /// read it. See decisions/sealed-content-type-inside-the-plaintext-frame.md.
        let contentType: UInt8
    }

    /// `plaintext` as KNST frames — the core's `knst_encode_chunks` since core 0.31, the one
    /// writer of the frame for every client (TODO 94). Empty when the body needs more than
    /// `maxChunks` frames.
    static func encodeChunks(plaintext: Data, messageId: UUID, contentType: UInt8) -> [Data] {
        guard let frames = knstEncodeChunks(payload: plaintext, contentType: contentType, messageId: messageId.uuidString) else {
            Log.error("Chunked message exceeds max chunks (\(plaintext.count) bytes)", category: "ChunkedDelivery")
            return []
        }
        return frames
    }

    /// One frame holding the whole payload, whatever its size (`totalChunks == 1`).
    ///
    /// For control carriers — call signal, delivery receipt, ping/ready — which are sent as a
    /// single message and never split. `encodeChunks` would cut a large SDP offer into several
    /// frames that these producers have no way to send, so they must not use it.
    ///
    /// The frame exists here only to carry `contentType` in byte 5: inside the ciphertext, where
    /// the server cannot read it, unlike `SealedInner.content_type`.
    static func frameWhole(_ payload: Data, contentType: UInt8, messageId: UUID) -> Data {
        // A UUID's string is always a valid message id, so the core's null cannot happen here.
        knstFrameWhole(payload: payload, contentType: contentType, messageId: messageId.uuidString) ?? Data()
    }

    /// Read a single-frame control carrier: its content type and its unframed payload.
    ///
    /// Returns nil for anything that is not one whole KNST frame — a multi-chunk body belongs to
    /// the reassembler, and unframed bytes are not ours. This is the sole post-decrypt routing
    /// input for content types 12 / 14 / 25 / 26; those no longer appear on `SealedInner`.
    static func controlFrame(_ data: Data) -> (contentType: UInt8, payload: Data)? {
        guard let parsed = parseChunk(data: data), parsed.totalChunks == 1 else { return nil }
        guard parsed.plaintextLength <= parsed.payload.count else { return nil }
        return (parsed.contentType, Data(parsed.payload.prefix(parsed.plaintextLength)))
    }

    static func extractPayloadString(from decryptedText: String) -> String? {
        guard decryptedText.hasPrefix(prefix) else {
            return nil
        }
        return String(decryptedText.dropFirst(prefix.count))
    }

    /// The header and payload of a frame, read by the core (`knst_parse`, core 0.31). Nil when
    /// `data` is not a frame: magic, version or a whole header missing.
    static func parseChunk(data: Data) -> ParsedChunk? {
        guard let frame = knstParse(frame: data) else { return nil }
        return ParsedChunk(
            // The core writes the dashed lowercase UUID; a malformed one cannot come back from it.
            messageId: UUID(uuidString: frame.messageId) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            chunkIndex: frame.chunkIndex,
            totalChunks: frame.totalChunks,
            plaintextLength: Int(frame.plaintextLength),
            payload: frame.payload,
            contentType: frame.contentType
        )
    }

}

