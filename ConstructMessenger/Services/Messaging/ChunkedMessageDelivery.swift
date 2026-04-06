import Foundation

struct ChunkedMessagePlan {
    let messageId: UUID
    let payloads: [String]
    let originalLength: Int
}

final class ChunkedMessageSender {
    static let shared = ChunkedMessageSender()

    private init() {}

    func buildPlan(plaintext: String, messageId: UUID) -> ChunkedMessagePlan {
        let data = Data(plaintext.utf8)
        let payloads = ChunkedMessageCodec.encodeChunks(plaintext: data, messageId: messageId)
        return ChunkedMessagePlan(messageId: messageId, payloads: payloads, originalLength: data.count)
    }

    func sendChunks(
        plan: ChunkedMessagePlan,
        senderId: String,
        recipientId: String,
        conversationId: String,
        timestamp: UInt64,
        preEncryptedFirst: CryptoManager.EncryptedMessageComponents? = nil,
        kemCiphertext: Data? = nil,
        kyberOtpkId: UInt32 = 0,
        replyToMessageId: String? = nil,
        onWirePayloadEncoded: ((String, Data) -> Void)? = nil
    ) async throws -> [SendMessageResponse] {
        var responses: [SendMessageResponse] = []

        for (index, payload) in plan.payloads.enumerated() {
            let components: CryptoManager.EncryptedMessageComponents
            if index == 0, let preEncryptedFirst {
                components = preEncryptedFirst
            } else {
                components = try CryptoManager.shared.encryptMessage(payload, for: recipientId)
            }

            // Each chunk gets a unique message ID derived from plan + chunk index
            let chunkMessageId = index == 0 ? plan.messageId.uuidString.lowercased()
                : "\(plan.messageId.uuidString.lowercased())-c\(index)"

            // Attach KEM ciphertext only to the first chunk (session-establishing message)
            let encryptedPayload = try WirePayloadCoder.encode(
                components,
                kemCiphertext: index == 0 ? kemCiphertext : nil,
                kyberOtpkId: index == 0 ? kyberOtpkId : 0
            )
            onWirePayloadEncoded?(chunkMessageId, encryptedPayload)

            let response = try await MessagingServiceClient.shared.sendMessage(
                messageId: chunkMessageId,
                recipientId: recipientId,
                senderId: senderId,
                conversationId: conversationId,
                encryptedPayload: encryptedPayload,
                timestamp: timestamp,
                // Only the first chunk carries reply metadata
                replyToMessageId: index == 0 ? replyToMessageId : nil
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

    func process(decryptedText: String) -> ChunkedMessageResult {
        guard let encoded = ChunkedMessageCodec.extractPayloadString(from: decryptedText) else {
            return .legacy(decryptedText)
        }

        guard let data = Data(base64Encoded: encoded) else {
            Log.info("⚠️ Chunked prefix found but Base64 decode failed, treating as legacy", category: "ChunkedDelivery")
            return .legacy(decryptedText)
        }

        guard let parsed = ChunkedMessageCodec.parseChunk(data: data) else {
            Log.info("⚠️ Chunked prefix found but header invalid, treating as legacy", category: "ChunkedDelivery")
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
            return .complete(text)
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
        return .complete(text)
    }

    private func cleanupExpired() {
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.startTime) <= ChunkedDeliveryConfig.reassemblyTimeout }
    }
}

enum ChunkedMessageResult {
    case legacy(String)
    case complete(String)
    case incomplete
    case invalid(String)
}

enum ChunkedMessageCodec {
    private static let prefix = "KNST1:"

    struct ParsedChunk {
        let messageId: UUID
        let chunkIndex: UInt16
        let totalChunks: UInt16
        let plaintextLength: Int
        let payload: Data
    }

    static func encodeChunks(plaintext: Data, messageId: UUID) -> [String] {
        let payloadSize = ChunkedDeliveryConfig.chunkPayloadSize
        let totalChunks = UInt16((plaintext.count + payloadSize - 1) / payloadSize)
        if totalChunks > ChunkedDeliveryConfig.maxChunks {
            Log.error("❌ Chunked message exceeds max chunks (\(totalChunks) > \(ChunkedDeliveryConfig.maxChunks))", category: "ChunkedDelivery")
            return []
        }
        let clampedTotal = max(totalChunks, 1)

        var payloads: [String] = []
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
            var data = Data(capacity: header.count + chunkData.count)
            data.append(header)
            data.append(chunkData)
            let encoded = data.base64EncodedString()
            payloads.append(prefix + encoded)
        }

        return payloads
    }

    private static func singleChunkBase64(plaintext: Data, messageId: UUID) -> String {
        let header = buildHeader(
            messageId: messageId,
            chunkIndex: 0,
            totalChunks: 1,
            plaintextLength: plaintext.count
        )
        var data = Data(capacity: header.count + plaintext.count)
        data.append(header)
        data.append(plaintext)
        return data.base64EncodedString()
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
