import Foundation
import SwiftProtobuf

struct ChunkedMessagePlan {
    let messageId: UUID
    let payloads: [Data]
    let originalLength: Int
}

final class ChunkedMessageSender {
    static let shared = ChunkedMessageSender()

    private init() {}

    func buildPlan(plaintext: Data, messageId: UUID) -> ChunkedMessagePlan {
        let payloads = ChunkedMessageCodec.encodeChunks(plaintext: plaintext, messageId: messageId)
        return ChunkedMessagePlan(messageId: messageId, payloads: payloads, originalLength: plaintext.count)
    }

    func sendChunks(
        plan: ChunkedMessagePlan,
        senderId: String,
        recipientId: String,
        conversationId: String,
        timestamp: UInt64,
        recipientIdentityKey: Data? = nil,
        onWirePayloadEncoded: ((String, Data) -> Void)? = nil
    ) async throws -> [SendMessageResponse] {
        var responses: [SendMessageResponse] = []

        for (index, payload) in plan.payloads.enumerated() {
            let chunkMessageId = index == 0 ? plan.messageId.uuidString.lowercased()
                : "\(plan.messageId.uuidString.lowercased())-c\(index)"

            // All encryption goes through the Rust orchestrator — PQXDH, DR state,
            // and wire-payload packing are handled inside handleEvent(.outgoingMessage).
            let encryptedPayload = try await OutboundSessionService.shared.encryptOutgoing(
                plaintext: payload,
                messageId: chunkMessageId,
                recipientId: recipientId
            )
            onWirePayloadEncoded?(chunkMessageId, encryptedPayload)

            // Build sealed inner bytes if policy says we should use stealth and we have the key.
            var sealedInner: Data? = nil
            if let recipientIK = recipientIdentityKey, await StealthPolicy.shared.shouldUseSealedSender() {
                do {
                    sealedInner = try await StealthSenderService.buildSealedInner(
                        recipientUserId: recipientId,
                        recipientIdentityKey: recipientIK,
                        encryptedPayload: encryptedPayload
                    )
                } catch {
                    Log.error("STEALTH: seal failed, sending without stealth: \(error)", category: "ChunkedDelivery")
                }
            }

            let response = try await MessagingServiceClient.shared.sendMessage(
                messageId: chunkMessageId,
                recipientId: recipientId,
                senderId: senderId,
                conversationId: conversationId,
                encryptedPayload: encryptedPayload,
                timestamp: timestamp,
                sealedInnerBytes: sealedInner
            )
            responses.append(response)

            if index < plan.payloads.count - 1 {
                let jitterMs = UInt64.random(in: ChunkedDeliveryConfig.chunkSendJitterMinMs...ChunkedDeliveryConfig.chunkSendJitterMaxMs)
                try await Task.sleep(nanoseconds: jitterMs * 1_000_000)
            }
        }

        return responses
    }
}

final class ChunkedMessageReassembler {

    /// Shared instance used by both MessageRouter (live stream) and
    /// BackgroundFetchManager (silent-push path).  Both paths run their
    /// reassembler interactions on the main thread, so no extra locking is needed.
    static let shared = ChunkedMessageReassembler()

    private struct PendingMessage {
        let messageId: UUID
        let totalChunks: UInt16
        let plaintextLength: Int
        var receivedChunks: [UInt16: Data]
        let startTime: Date

        var isComplete: Bool {
            receivedChunks.count == Int(totalChunks)
        }
    }

    private var pending: [UUID: PendingMessage] = [:]

    /// Process binary decrypted data — supports both binary KNST frames and legacy formats.
    /// Extracts `QuotedMessage` from `MessageContent` proto when present.
    func process(data: Data) -> ChunkedMessageResult {
        // ── Binary KNST frame ────────────────────────────────────────────────
        let magic = ChunkedDeliveryConfig.magic
        if data.count >= magic.count + 1,
           data.prefix(magic.count).elementsEqual(magic),
           data[magic.count] == ChunkedDeliveryConfig.version
        {
            guard let parsed = ChunkedMessageCodec.parseChunk(data: data) else {
                Log.info("Binary KNST magic found but header invalid, falling through", category: "ChunkedDelivery")
                return decodeRaw(data)
            }
            return processKnstChunk(parsed)
        }

        // ── Legacy KNST1:<base64> text framing ──────────────────────────────
        let prefix = Data(ChunkedMessageCodec.legacyPrefix.utf8)
        if data.starts(with: prefix), let text = String(data: data, encoding: .utf8) {
            return process(decryptedText: text)
        }

        return decodeRaw(data)
    }

    private func processKnstChunk(_ parsed: ChunkedMessageCodec.ParsedChunk) -> ChunkedMessageResult {
        cleanupExpired()
        if parsed.totalChunks == 1 {
            let trimmed = parsed.payload.prefix(parsed.plaintextLength)
            return decodeAssembled(Data(trimmed))
        }
        if parsed.totalChunks > ChunkedDeliveryConfig.maxChunks {
            return .invalid("total_chunks exceeds max")
        }
        var entry = pending[parsed.messageId] ?? PendingMessage(
            messageId: parsed.messageId,
            totalChunks: parsed.totalChunks,
            plaintextLength: parsed.plaintextLength,
            receivedChunks: [:],
            startTime: Date()
        )
        entry.receivedChunks[parsed.chunkIndex] = parsed.payload
        pending[parsed.messageId] = entry
        guard entry.isComplete else { return .incomplete }
        var assembled = Data()
        for index in 0..<entry.totalChunks {
            guard let chunk = entry.receivedChunks[index] else { return .incomplete }
            assembled.append(chunk)
        }
        pending.removeValue(forKey: parsed.messageId)
        guard entry.plaintextLength <= assembled.count else {
            return .invalid("Plaintext length exceeds assembled size")
        }
        return decodeAssembled(Data(assembled.prefix(entry.plaintextLength)))
    }

    private func decodeAssembled(_ data: Data) -> ChunkedMessageResult {
        if let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: data),
           content.content != nil
        {
            if case .edit(let editMsg) = content.content {
                return .edit(targetMessageID: editMsg.targetMessageID, newText: editMsg.newText, newMedia: editMsg.newMedia)
            }
            let (text, quoted) = extract(content)
            return .assembled(text: text, quoted: quoted)
        }
        // Binary profile share before the UTF-8 fallback — it's a more specific, structured format,
        // and must surface as a profile (not a "__PROFILE_BINARY__" placeholder string).
        if ProfileShareData.fromBinaryData(data) != nil {
            return .profile(data)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.isEmpty ? .invalid("empty plaintext") : .assembled(text: text, quoted: nil)
        }
        return .invalid("non-decodable binary (\(data.count) bytes)")
    }

    private func decodeRaw(_ data: Data) -> ChunkedMessageResult {
        // Try proto first (single-message delivery without KNST framing)
        if let content = try? Shared_Proto_Messaging_V1_MessageContent(serializedBytes: data),
           content.content != nil
        {
            if case .edit(let editMsg) = content.content {
                return .edit(targetMessageID: editMsg.targetMessageID, newText: editMsg.newText, newMedia: editMsg.newMedia)
            }
            let (text, quoted) = extract(content)
            return .assembled(text: text, quoted: quoted)
        }
        // Binary profile share (new format, no JSON) — check before the UTF-8 fallback so it
        // surfaces as a profile, not a "__PROFILE_BINARY__" placeholder text message.
        if ProfileShareData.fromBinaryData(data) != nil {
            return .profile(data)
        }
        // Session control strings, legacy plain-text messages
        if let text = String(data: data, encoding: .utf8) {
            return text.isEmpty ? .invalid("empty plaintext") : .legacy(text)
        }
        return .invalid("non-decodable binary (\(data.count) bytes)")
    }

    private func extract(_ content: Shared_Proto_Messaging_V1_MessageContent)
        -> (String, Shared_Proto_Messaging_V1_QuotedMessage?)
    {
        switch content.content {
        case .text(let msg):
            return (msg.text, msg.hasQuoted ? msg.quoted : nil)
        case .mediaAlbum(let album):
            // Binary media → re-serialize to the local media JSON the views parse.
            return (MediaWireCodec.mediaJSON(from: album) ?? "", album.hasQuoted ? album.quoted : nil)
        default:
            return ("", nil)
        }
    }

    /// Legacy path: process a string decrypted with the old base64-KNST format.
    /// Kept for BackgroundFetchManager compatibility with pre-migration messages.
    func process(decryptedText: String) -> ChunkedMessageResult {
        guard let encoded = ChunkedMessageCodec.extractPayloadString(from: decryptedText) else {
            return .legacy(decryptedText)
        }

        guard let data = Data(base64Encoded: encoded) else {
            Log.info("Chunked prefix found but Base64 decode failed, treating as legacy", category: "ChunkedDelivery")
            return .legacy(decryptedText)
        }

        guard let parsed = ChunkedMessageCodec.parseChunk(data: data) else {
            Log.info("Chunked prefix found but header invalid, treating as legacy", category: "ChunkedDelivery")
            return .legacy(decryptedText)
        }

        cleanupExpired()

        if parsed.totalChunks == 1 {
            let payload = parsed.payload
            guard parsed.plaintextLength <= payload.count else {
                return .invalid("Plaintext length exceeds payload size")
            }
            let trimmed = payload.prefix(parsed.plaintextLength)
            guard let text = String(data: trimmed, encoding: .utf8) else {
                return .invalid("Failed to decode plaintext")
            }
            return .assembled(text: text, quoted: nil)
        }

        if parsed.totalChunks > ChunkedDeliveryConfig.maxChunks {
            return .invalid("total_chunks exceeds max")
        }

        var entry = pending[parsed.messageId] ?? PendingMessage(
            messageId: parsed.messageId,
            totalChunks: parsed.totalChunks,
            plaintextLength: parsed.plaintextLength,
            receivedChunks: [:],
            startTime: Date()
        )

        entry.receivedChunks[parsed.chunkIndex] = parsed.payload
        pending[parsed.messageId] = entry

        guard entry.isComplete else {
            return .incomplete
        }

        var assembled = Data()
        for index in 0..<entry.totalChunks {
            guard let chunk = entry.receivedChunks[index] else {
                return .incomplete
            }
            assembled.append(chunk)
        }

        pending.removeValue(forKey: parsed.messageId)

        guard entry.plaintextLength <= assembled.count else {
            return .invalid("Plaintext length exceeds assembled size")
        }
        let trimmed = assembled.prefix(entry.plaintextLength)
        guard let text = String(data: trimmed, encoding: .utf8) else {
            return .invalid("Failed to decode assembled plaintext")
        }
        return .assembled(text: text, quoted: nil)
    }

    private func cleanupExpired() {
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.startTime) <= ChunkedDeliveryConfig.reassemblyTimeout }
    }
}

enum ChunkedMessageResult {
    /// Successfully decoded message (KNST chunked or direct proto).
    /// `quoted` is non-nil when the sender embedded a reply reference in the proto plaintext.
    case assembled(text: String, quoted: Shared_Proto_Messaging_V1_QuotedMessage?)
    /// Non-KNST data decoded as plain UTF-8 (session control strings, legacy messages).
    case legacy(String)
    /// Assembled binary profile-share payload (raw bytes; decode with `ProfileShareData.fromBinaryData`).
    /// Must NOT be rendered as text — the caller turns it into a profile bubble.
    case profile(Data)
    case incomplete
    case invalid(String)
    /// Modern edit inside MessageContent.
    case edit(targetMessageID: String, newText: Shared_Proto_Messaging_V1_TextMessage, newMedia: Shared_Proto_Messaging_V1_MediaMessage)
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
    }

    static func encodeChunks(plaintext: Data, messageId: UUID) -> [Data] {
        let payloadSize = ChunkedDeliveryConfig.chunkPayloadSize
        let totalChunks = UInt16((plaintext.count + payloadSize - 1) / payloadSize)
        if totalChunks > ChunkedDeliveryConfig.maxChunks {
            Log.error("Chunked message exceeds max chunks (\(totalChunks) > \(ChunkedDeliveryConfig.maxChunks))", category: "ChunkedDelivery")
            return []
        }
        let clampedTotal = max(totalChunks, 1)

        var payloads: [Data] = []
        payloads.reserveCapacity(Int(clampedTotal))

        for index in 0..<Int(clampedTotal) {
            let start = index * payloadSize
            let end = min(start + payloadSize, plaintext.count)
            let chunkData = plaintext.subdata(in: start..<end)
            let header = buildHeader(
                messageId: messageId,
                chunkIndex: UInt16(index),
                totalChunks: clampedTotal,
                plaintextLength: plaintext.count
            )
            var frame = Data(capacity: header.count + chunkData.count)
            frame.append(header)
            frame.append(chunkData)
            payloads.append(frame)
        }

        return payloads
    }

    static func extractPayloadString(from decryptedText: String) -> String? {
        guard decryptedText.hasPrefix(prefix) else {
            return nil
        }
        return String(decryptedText.dropFirst(prefix.count))
    }

    static func parseChunk(data: Data) -> ParsedChunk? {
        guard data.count >= ChunkedDeliveryConfig.headerSize else {
            return nil
        }

        let magic = [UInt8](data.prefix(4))
        guard magic == ChunkedDeliveryConfig.magic else {
            return nil
        }

        let version = data[4]
        guard version == ChunkedDeliveryConfig.version else {
            return nil
        }

        let messageIdData = data.subdata(in: 6..<22)
        let messageId = UUID(uuid: messageIdData.toUUIDBytes())

        let chunkIndex = data.subdata(in: 22..<24).toUInt16()
        let totalChunks = data.subdata(in: 24..<26).toUInt16()
        let plaintextLength = Int(data.subdata(in: 26..<30).toUInt32())

        let payload = data.subdata(in: 30..<data.count)
        return ParsedChunk(
            messageId: messageId,
            chunkIndex: chunkIndex,
            totalChunks: totalChunks,
            plaintextLength: plaintextLength,
            payload: payload
        )
    }

    private static func buildHeader(
        messageId: UUID,
        chunkIndex: UInt16,
        totalChunks: UInt16,
        plaintextLength: Int
    ) -> Data {
        var data = Data(capacity: ChunkedDeliveryConfig.headerSize)
        data.append(contentsOf: ChunkedDeliveryConfig.magic)
        data.append(ChunkedDeliveryConfig.version)
        data.append(ChunkedDeliveryConfig.flags)
        data.append(contentsOf: messageId.uuidBytes)
        data.append(contentsOf: chunkIndex.bigEndianBytes)
        data.append(contentsOf: totalChunks.bigEndianBytes)
        data.append(contentsOf: UInt32(plaintextLength).bigEndianBytes)
        return data
    }
}

private extension UUID {
    var uuidBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}

private extension Data {
    func toUInt16() -> UInt16 {
        let bytes = [UInt8](self)
        guard bytes.count >= 2 else { return 0 }
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    func toUInt32() -> UInt32 {
        let bytes = [UInt8](self)
        guard bytes.count >= 4 else { return 0 }
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }

    func toUUIDBytes() -> uuid_t {
        let bytes = [UInt8](self)
        guard bytes.count >= 16 else {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }
        return (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}
